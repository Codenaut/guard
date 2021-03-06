defmodule Guard.Authenticator do
  alias Guard.{Repo, User, UserApiKey, Mailer, Users}

  defexception message: "not_authenticated"

  @access_token "access"
  @login_token "login"
  @password_reset_token "password_reset"

  defp pin_range() do
    Application.get_env(:guard, :pin_range, 100_000..999_999)
  end

  defp pin_lifespan_mins() do
    Application.get_env(:guard, :pin_lifespan_mins, 60)
  end

  defp random_bytes() do
    :crypto.hash(:sha512, :crypto.strong_rand_bytes(512)) |> Base.encode64()
  end

  def create_user_by_email(email, extra \\ nil) do
    create_user(%{"email" => email, "username" => User.downcase(email)}, extra)
  end

  def create_user_by_mobile(mobile, extra \\ nil) do
    create_user(%{"mobile" => mobile, "username" => User.clean_mobile_number(mobile)}, extra)
  end

  def send_welcome_email(%User{} = user) do
    {:ok, token, _} = generate_login_claim(user)
    {:ok, pin, user} = generate_email_pin(user)
    Mailer.send_welcome_email(user, token, pin)
  end

  def send_confirm_email(%User{} = user) do
    {:ok, token, _} = generate_login_claim(user)
    {:ok, pin, user} = generate_email_pin(user)
    Mailer.send_confirm_email(user, token, pin)
  end

  def send_reset_password_email(%User{} = user) do
    {:ok, token, _} = generate_password_reset_claim(user)
    {:ok, pin, user} = generate_email_pin(user)
    Mailer.send_reset_password_link(user, token, pin)
  end

  def send_login_email(%User{} = user) do
    {:ok, token, _} = generate_login_claim(user)
    {:ok, pin, user} = generate_email_pin(user)
    Mailer.send_login_link(user, token, pin)
  end

  def send_contact_confirmation(%User{} = user, opts \\ [email: true, mobile: true]) do
    user =
      if opts[:email] && user.requested_email && user.requested_email !== user.email do
        {:ok, token, _} = generate_login_claim(user)
        {:ok, pin, user} = generate_email_pin(user)
        Mailer.send_confirm_email(user, token, pin)
        user
      else
        user
      end

    if opts[:mobile] && user.requested_mobile && user.requested_mobile != user.mobile do
      {:ok, pin, user} = generate_pin(user)
      Guard.Sms.send_confirm_mobile(user, pin)
      user
    else
      user
    end
  end

  def create_user_by_username(username, password, extra \\ nil) do
    map = %{"username" => username, "password" => password}
    create_user(map, extra)
  end

  def create_and_confirm_user(user_map) do
    case create_user(user_map) do
      {:ok, user, jwt, extra} ->
        send_welcome_email(user)
        {:ok, user, jwt, extra}

      other ->
        other
    end
  end

  def create_user(user_map, extra \\ nil) when is_map(user_map) do
    # Only accept very few keys when creating user
    user =
      Map.take(user_map, ["username", "password", "password_confirmation", "fullname", "locale"])

    email = Map.get(user_map, "email")
    user = Map.put(user, "requested_email", email)
    mobile = Map.get(user_map, "mobile")
    user = Map.put(user, "requested_mobile", mobile)
    username = Map.get(user, "username")

    username =
      if is_nil(username) do
        email || mobile
      else
        username
      end

    user = Map.put(user, "username", username)

    # Generate password if user has not provided one
    user =
      if Map.get(user, "password") do
        user
      else
        password = random_bytes()
        Map.put(user, "password", password)
      end

    Repo.transaction(fn ->
      with {:ok, user} <- Users.create_user(user),
           {:ok, jwt, _full_claims} <- generate_access_claim(user),
           {:ok, response} <-
             (try do
                if extra do
                  extra.(user)
                else
                  {:ok, nil}
                end
              rescue
                error -> {:error, error}
              end) do
        {:ok, user, jwt, response}
      else
        error -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, response} ->
        response

      {:error, {:error, %Ecto.Changeset{} = changeset}} ->
        {:error, Repo.changeset_errors(changeset), changeset}

      {:error, {:error, error}} ->
        {:error, Guard.Controller.translate_error(error), error}

      {:error, error} ->
        {:error, Guard.Controller.translate_error(error), error}
    end
  end

  defp with_context(user, conn) do
    if user do
      user
      |> Map.put(:context, Guard.Session.get_context(conn))
    end
  end

  def current_user(conn) do
    conn
    |> Guardian.Plug.current_resource()
    |> case do
      nil -> nil
      user = %User{} -> user
      key = %UserApiKey{} -> Users.get!(key.user_id)
      _ -> nil
    end
    |> with_context(conn)
  end

  def authenticated_user!(conn) do
    user = current_user(conn)

    if user do
      user
    else
      raise Guard.Authenticator, message: "not_authenticated"
    end
  end

  def request_email_change(%User{} = user, email) do
    Users.update_user(user, %{"requested_email" => email})
  end

  def request_mobile_change(%User{} = user, mobile) do
    Users.update_user(user, %{"requested_mobile" => mobile})
  end

  def change_password(%User{} = user, new_password) do
    Users.update_user(user, %{password: new_password})
  end

  defp check_user_role_permissions(permissions, users_perms) do
    Enum.reduce_while(permissions, true, fn p, _acc ->
      if Enum.any?(users_perms, fn up -> p == up end), do: {:cont, true}, else: {:halt, false}
    end)
  end

  defp check_user_perms(user, key, ps) do
    case Map.get(user.perms, key) do
      nil ->
        false

      users_perms ->
        check_user_role_permissions(ps, users_perms)
    end
  end

  @doc """
    Check that the given user has all the provider permissions


  ## Examples

  iex> Guard.Authenticator.has_perms?(user, %{"admin" => ["read", "write"]})
  false
  """
  def has_perms?(%User{} = user, %{} = required_perms) do
    !is_nil(user.perms) &&
      Enum.reduce_while(required_perms, true, fn {key, ps}, _acc ->
        if check_user_perms(user, key, ps) do
          {:cont, true}
        else
          {:halt, false}
        end
      end)
  end

  def has_perms?(%User{} = user, [_ | _] = perm_names) do
    Enum.reduce_while(perm_names, true, fn v, _acc ->
      if has_perms?(user, v) do
        {:cont, true}
      else
        {:cont, false}
      end
    end)
  end

  def has_perms?(%User{} = user, perm_name) do
    !is_nil(user.perms) && Map.has_key?(user.perms, perm_name)
  end

  def current_permissions(%Plug.Conn{} = conn) do
    Guardian.Plug.current_claims(conn)
    |> claims_to_permissions()
  end

  def claims_to_permissions(claims) do
    Guard.Jwt.decode_permissions(claims["pem"])
  end

  def all_permissions?(conn, permissions) do
    conn
    |> current_permissions()
    |> Guard.Jwt.all_permissions?(permissions)
  end

  def any_permissions?(conn, permissions) do
    conn
    |> current_permissions()
    |> Guard.Jwt.any_permissions?(permissions)
  end

  def add_perms(%User{} = user, perms) do
    case user do
      nil ->
        {:error}

      user ->
        old_perms = user.perms || %{}
        Repo.update(User.changeset(user, %{"perms" => Map.merge(old_perms, perms)}))
    end
  end

  def drop_perm(%User{} = user, name) do
    case user do
      nil ->
        {:error}

      user ->
        perms = user.perms || %{}
        Repo.update(User.changeset(user, %{"perms" => Map.delete(perms, name)}))
    end
  end

  def bump_to_admin(username) do
    case Users.get_by_username(username) do
      nil -> {:error}
      user -> add_perms(user, %{admin: [:read, :write]})
    end
  end

  def drop_admin(username) do
    case Users.get_by_username(username) do
      nil -> {:error}
      user -> drop_perm(user, "admin")
    end
  end

  defp process_perms(perms) do
    if perms do
      perms
      |> Enum.to_list()
      |> Enum.into(%{}, fn {k, v} ->
        {k, Enum.map(v, fn v -> if is_atom(v), do: v, else: String.to_atom(v) end)}
      end)
    else
      nil
    end
  end

  defp can_switch_user?(claims) do
    case Application.get_env(:guard, Guard.Guardian)[:switch_user_permission] do
      nil ->
        false

      true ->
        true

      required_permission ->
        claims
        |> Guard.Jwt.decode_permissions_from_claims()
        |> Guard.Jwt.all_permissions?(required_permission)
    end
  end

  def switch_user(conn, %User{} = user) do
    case current_claims(conn) do
      {:ok, claims} ->
        if can_switch_user?(claims) do
          root_user = authenticated_user!(conn)
          generate_switched_user_access_claim(user, root_user.id, claims)
        else
          {:error, :forbidden}
        end

      other ->
        other
    end
  end

  def reset_user(conn) do
    case current_claims(conn) do
      {:ok, claims} ->
        case claims do
          %{"usr" => user_id} ->
            user = Users.get!(user_id)
            generate_access_claim(user)

          _ ->
            {:error, :not_switched}
        end

      other ->
        other
    end
  end

  defp generate_switched_user_access_claim(%User{} = user, root_user_id, claims) do
    generate_access_claim(user, Map.put(claims, :usr, root_user_id))
  end

  def sign_in(conn, %User{} = user, claims \\ %{}) do
    perms = process_perms(user.perms) || %{}

    conn
    |> Guard.Jwt.Plug.sign_in(user, claims, token_type: @access_token, perms: perms)
  end

  def generate_access_claim(%User{} = user, claims \\ %{}) do
    perms = process_perms(user.perms) || %{}
    Guard.Jwt.encode_and_sign(user, claims, token_type: @access_token, perms: perms)
  end

  def generate_login_claim(%User{} = user, email \\ nil) do
    Guard.Jwt.encode_and_sign(user, %{requested_email: email || user.requested_email},
      token_type: @login_token,
      token_ttl: Application.get_env(:guard, :login_ttl, {12, :hours})
    )
  end

  def generate_password_reset_claim(%User{} = user) do
    Guard.Jwt.encode_and_sign(user, %{},
      token_type: @password_reset_token,
      token_ttl: Application.get_env(:guard, :login_ttl, {12, :hours})
    )
  end

  def current_claims(conn) do
    {:ok, Guardian.Plug.current_claims(conn)}
  end

  def current_claim_type(conn) do
    case conn |> current_claims do
      {:ok, claims} ->
        Map.get(claims, "typ")

      {:error, _} ->
        nil
    end
  end

  def use_pin(user, pin) do
    case User.validate_pin(user, pin) do
      :ok -> clear_pin(user)
      other -> other
    end
  end

  def use_email_pin(user, pin) do
    case User.validate_email_pin(user, pin) do
      :ok -> clear_email_pin(user)
      other -> other
    end
  end

  def use_either_pin(user, pin) do
    case User.validate_pin(user, pin) do
      :ok ->
        clear_pin(user)

      other ->
        if user.enc_email_pin, do: use_email_pin(user, pin), else: other
    end
  end

  def generate_pin(user) do
    {:ok, exp_time} =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> Kernel.+(60 * pin_lifespan_mins())
      |> DateTime.from_unix()

    generate_pin(user, exp_time)
  end

  def generate_pin(user, exp_time) do
    pin = to_string(Enum.random(pin_range()))

    case Users.update_user(user, %{pin: pin, pin_expiration: exp_time}) do
      {:ok, user} -> {:ok, pin, user}
      other -> other
    end
  end

  def clear_pin(user) do
    Users.update_user(user, %{enc_pin: nil, pin_expiration: nil})
  end

  def generate_email_pin(user) do
    {:ok, exp_time} =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> Kernel.+(60 * pin_lifespan_mins())
      |> DateTime.from_unix()

    generate_email_pin(user, exp_time)
  end

  def generate_email_pin(user, exp_time) do
    pin = to_string(Enum.random(pin_range()))

    case Users.update_user(user, %{email_pin: pin, email_pin_expiration: exp_time}) do
      {:ok, user} -> {:ok, pin, user}
      other -> other
    end
  end

  def clear_email_pin(user) do
    Users.update_user(user, %{enc_email_pin: nil, email_pin_expiration: nil})
  end

  def create_api_key(%User{} = user, permissions \\ %{}) do
    Users.create_api_key(user, permissions)
  end

  def delete_api_key(key) do
    Users.delete_api_key(key)
  end

  def list_api_keys(%User{} = user) do
    Users.list_api_keys(user)
  end
end
