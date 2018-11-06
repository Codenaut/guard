defmodule Guard.Controller.Session do
  use Phoenix.Controller
  import Guard.Controller, only: [send_error: 2, send_error: 3]

  def call(conn, opts) do
    try do
      super(conn, opts)
    rescue
      error -> send_error(conn, error, :internal_server_error)
    end
  end

  defp process_session(conn, {:ok, user}) do
    case Guard.Authenticator.generate_access_claim(user) do
      {:ok, jwt, _full_claims} ->
        conn
        |> put_status(:created)
        |> json(%{jwt: jwt, user: user, perms: user.perms})
      {:error, error} ->
        send_error(conn, error)
    end
  end 

  defp process_session(conn, {:error, message}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: message})
  end


  def restore(conn, %{"token" => token}) do
    process_session conn, Guard.Session.authenticate({:jwt, token})
  end  

  def create(conn, %{"session" => session_params}) do
    process_session conn, Guard.Session.authenticate(session_params) 
  end

  def create(conn, params) do
    process_session conn, Guard.Session.authenticate(params) 
  end

  def delete(conn, _) do
    case Guard.Authenticator.current_claims(conn) do
      {:ok, claims} -> conn
      |> Guardian.Plug.current_token
      |> Guard.Guardian.revoke(claims)
      _ -> nil
    end
    conn
    |> json(%{ok: true})
  end
end