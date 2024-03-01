defmodule PlausibleWeb.AuthController do
  use PlausibleWeb, :controller
  use Plausible.Repo

  alias Plausible.{Auth, RateLimit}
  alias Plausible.Billing.Quota
  alias PlausibleWeb.TwoFactor

  require Logger

  plug(
    PlausibleWeb.RequireLoggedOutPlug
    when action in [
           :register,
           :register_from_invitation,
           :login_form,
           :login,
           :verify_2fa_form,
           :verify_2fa,
           :verify_2fa_recovery_code_form,
           :verify_2fa_recovery_code
         ]
  )

  plug(
    PlausibleWeb.RequireAccountPlug
    when action in [
           :user_settings,
           :save_settings,
           :update_email,
           :cancel_update_email,
           :new_api_key,
           :create_api_key,
           :delete_api_key,
           :delete_me,
           :activate_form,
           :activate,
           :request_activation_code,
           :initiate_2fa,
           :verify_2fa_setup_form,
           :verify_2fa_setup,
           :disable_2fa,
           :generate_2fa_recovery_codes
         ]
  )

  plug(
    :clear_2fa_user
    when action not in [
           :verify_2fa_form,
           :verify_2fa,
           :verify_2fa_recovery_code_form,
           :verify_2fa_recovery_code
         ]
  )

  defp clear_2fa_user(conn, _opts) do
    TwoFactor.Session.clear_2fa_user(conn)
  end

  def register(conn, %{"user" => %{"email" => email, "password" => password}}) do
    with {:ok, user} <- login_user(conn, email, password) do
      conn = set_user_session(conn, user)

      if user.email_verified do
        redirect(conn, to: Routes.site_path(conn, :new))
      else
        Auth.EmailVerification.issue_code(user)
        redirect(conn, to: Routes.auth_path(conn, :activate_form))
      end
    end
  end

  def register_from_invitation(conn, %{"user" => %{"email" => email, "password" => password}}) do
    with {:ok, user} <- login_user(conn, email, password) do
      conn = set_user_session(conn, user)

      if user.email_verified do
        redirect(conn, to: Routes.site_path(conn, :index))
      else
        Auth.EmailVerification.issue_code(user)
        redirect(conn, to: Routes.auth_path(conn, :activate_form))
      end
    end
  end

  def activate_form(conn, _params) do
    user = conn.assigns.current_user

    render(conn, "activate.html",
      has_email_code?: Plausible.Users.has_email_code?(user),
      has_any_invitations?: Plausible.Site.Memberships.pending?(user.email),
      has_any_memberships?: Plausible.Site.Memberships.any?(user),
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def activate(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]

    has_any_invitations? = Plausible.Site.Memberships.pending?(user.email)
    has_any_memberships? = Plausible.Site.Memberships.any?(user)

    case Auth.EmailVerification.verify_code(user, code) do
      :ok ->
        cond do
          has_any_memberships? ->
            handle_email_updated(conn)

          has_any_invitations? ->
            redirect(conn, to: Routes.site_path(conn, :index))

          true ->
            redirect(conn, to: Routes.site_path(conn, :new))
        end

      {:error, :incorrect} ->
        render(conn, "activate.html",
          error: "Incorrect activation code",
          has_email_code?: true,
          has_any_invitations?: has_any_invitations?,
          has_any_memberships?: has_any_memberships?,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      {:error, :expired} ->
        render(conn, "activate.html",
          error: "Code is expired, please request another one",
          has_email_code?: false,
          has_any_invitations?: has_any_invitations?,
          has_any_memberships?: has_any_memberships?,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def request_activation_code(conn, _params) do
    user = conn.assigns.current_user
    Auth.EmailVerification.issue_code(user)

    conn
    |> put_flash(:success, "Activation code was sent to #{user.email}")
    |> redirect(to: Routes.auth_path(conn, :activate_form))
  end

  def password_reset_request_form(conn, _) do
    render(conn, "password_reset_request_form.html",
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def password_reset_request(conn, %{"email" => ""}) do
    render(conn, "password_reset_request_form.html",
      error: "Please enter an email address",
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def password_reset_request(conn, %{"email" => email} = params) do
    if PlausibleWeb.Captcha.verify(params["h-captcha-response"]) do
      user = Repo.get_by(Plausible.Auth.User, email: email)

      if user do
        token = Auth.Token.sign_password_reset(email)
        url = PlausibleWeb.Endpoint.url() <> "/password/reset?token=#{token}"
        email_template = PlausibleWeb.Email.password_reset_email(email, url)
        Plausible.Mailer.deliver_later(email_template)

        Logger.debug(
          "Password reset e-mail sent. In dev environment GET /sent-emails for details."
        )

        render(conn, "password_reset_request_success.html",
          email: email,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      else
        render(conn, "password_reset_request_success.html",
          email: email,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      end
    else
      render(conn, "password_reset_request_form.html",
        error: "Please complete the captcha to reset your password",
        layout: {PlausibleWeb.LayoutView, "focus.html"}
      )
    end
  end

  def password_reset_form(conn, params) do
    case Auth.Token.verify_password_reset(params["token"]) do
      {:ok, %{email: email}} ->
        render(conn, "password_reset_form.html",
          connect_live_socket: true,
          email: email,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      {:error, :expired} ->
        render_error(
          conn,
          401,
          "Your token has expired. Please request another password reset link."
        )

      {:error, _} ->
        render_error(
          conn,
          401,
          "Your token is invalid. Please request another password reset link."
        )
    end
  end

  def password_reset(conn, _params) do
    conn
    |> put_flash(:login_title, "Password updated successfully")
    |> put_flash(:login_instructions, "Please log in with your new credentials")
    |> put_session(:current_user_id, nil)
    |> delete_resp_cookie("logged_in")
    |> redirect(to: Routes.auth_path(conn, :login_form))
  end

  def login(conn, %{"email" => email, "password" => password}) do
    with {:ok, user} <- login_user(conn, email, password) do
      if Auth.TOTP.enabled?(user) and not TwoFactor.Session.remember_2fa?(conn, user) do
        conn
        |> TwoFactor.Session.set_2fa_user(user)
        |> redirect(to: Routes.auth_path(conn, :verify_2fa))
      else
        set_user_session_and_redirect(conn, user)
      end
    end
  end

  defp login_user(conn, email, password) do
    with :ok <- check_ip_rate_limit(conn),
         {:ok, user} <- find_user(email),
         :ok <- check_user_rate_limit(user),
         :ok <- check_password(user, password) do
      {:ok, user}
    else
      :wrong_password ->
        maybe_log_failed_login_attempts("wrong password for #{email}")

        render(conn, "login_form.html",
          error: "Wrong email or password. Please try again.",
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      :user_not_found ->
        maybe_log_failed_login_attempts("user not found for #{email}")
        Plausible.Auth.Password.dummy_calculation()

        render(conn, "login_form.html",
          error: "Wrong email or password. Please try again.",
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      {:rate_limit, _} ->
        maybe_log_failed_login_attempts("too many logging attempts for #{email}")

        render_error(
          conn,
          429,
          "Too many login attempts. Wait a minute before trying again."
        )
    end
  end

  defp redirect_to_login(conn) do
    redirect(conn, to: Routes.auth_path(conn, :login_form))
  end

  defp set_user_session_and_redirect(conn, user) do
    login_dest = get_session(conn, :login_dest) || Routes.site_path(conn, :index)

    conn
    |> set_user_session(user)
    |> put_session(:login_dest, nil)
    |> redirect(external: login_dest)
  end

  defp set_user_session(conn, user) do
    conn
    |> TwoFactor.Session.clear_2fa_user()
    |> put_session(:current_user_id, user.id)
    |> put_resp_cookie("logged_in", "true",
      http_only: false,
      max_age: 60 * 60 * 24 * 365 * 5000
    )
  end

  defp maybe_log_failed_login_attempts(message) do
    if Application.get_env(:plausible, :log_failed_login_attempts) do
      Logger.warning("[login] #{message}")
    end
  end

  @login_interval 60_000
  @login_limit 5
  @email_change_limit 2
  @email_change_interval :timer.hours(1)

  defp check_ip_rate_limit(conn) do
    ip_address = PlausibleWeb.RemoteIP.get(conn)

    case RateLimit.check_rate("login:ip:#{ip_address}", @login_interval, @login_limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:rate_limit, :ip_address}
    end
  end

  defp check_user_rate_limit(user) do
    case RateLimit.check_rate("login:user:#{user.id}", @login_interval, @login_limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:rate_limit, :user}
    end
  end

  defp find_user(email) do
    user =
      Repo.one(
        from(u in Plausible.Auth.User,
          where: u.email == ^email
        )
      )

    if user, do: {:ok, user}, else: :user_not_found
  end

  defp check_password(user, password) do
    if Plausible.Auth.Password.match?(password, user.password_hash || "") do
      :ok
    else
      :wrong_password
    end
  end

  def login_form(conn, _params) do
    render(conn, "login_form.html", layout: {PlausibleWeb.LayoutView, "focus.html"})
  end

  def user_settings(conn, _params) do
    user = conn.assigns.current_user
    settings_changeset = Auth.User.settings_changeset(user)
    email_changeset = Auth.User.settings_changeset(user)

    render_settings(conn,
      settings_changeset: settings_changeset,
      email_changeset: email_changeset
    )
  end

  def initiate_2fa_setup(conn, _params) do
    case Auth.TOTP.initiate(conn.assigns.current_user) do
      {:ok, user, %{totp_uri: totp_uri, secret: secret}} ->
        render(conn, "initiate_2fa_setup.html", user: user, totp_uri: totp_uri, secret: secret)

      {:error, :already_setup} ->
        conn
        |> put_flash(:error, "Two-Factor Authentication is already setup for this account.")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")
    end
  end

  def verify_2fa_setup_form(conn, _params) do
    if Auth.TOTP.initiated?(conn.assigns.current_user) do
      render(conn, "verify_2fa_setup.html")
    else
      redirect(conn, to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")
    end
  end

  def verify_2fa_setup(conn, %{"code" => code}) do
    case Auth.TOTP.enable(conn.assigns.current_user, code) do
      {:ok, _, %{recovery_codes: codes}} ->
        conn
        |> put_flash(:success, "Two-Factor Authentication is fully enabled")
        |> render("generate_2fa_recovery_codes.html", recovery_codes: codes, from_setup: true)

      {:error, :invalid_code} ->
        conn
        |> put_flash(:error, "The provided code is invalid. Please try again")
        |> render("verify_2fa_setup.html")

      {:error, :not_initiated} ->
        conn
        |> put_flash(:error, "Please enable Two-Factor Authentication for this account first.")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")
    end
  end

  def disable_2fa(conn, %{"password" => password}) do
    case Auth.TOTP.disable(conn.assigns.current_user, password) do
      {:ok, _} ->
        conn
        |> TwoFactor.Session.clear_remember_2fa()
        |> put_flash(:success, "Two-Factor Authentication is disabled")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")

      {:error, :invalid_password} ->
        conn
        |> put_flash(:error, "Incorrect password provided")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")
    end
  end

  def generate_2fa_recovery_codes(conn, %{"password" => password}) do
    case Auth.TOTP.generate_recovery_codes(conn.assigns.current_user, password) do
      {:ok, codes} ->
        conn
        |> put_flash(:success, "New Recovery Codes generated")
        |> render("generate_2fa_recovery_codes.html", recovery_codes: codes, from_setup: false)

      {:error, :invalid_password} ->
        conn
        |> put_flash(:error, "Incorrect password provided")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")

      {:error, :not_enabled} ->
        conn
        |> put_flash(:error, "Please enable Two-Factor Authentication for this account first.")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#setup-2fa")
    end
  end

  def verify_2fa_form(conn, _) do
    case TwoFactor.Session.get_2fa_user(conn) do
      {:ok, user} ->
        if Auth.TOTP.enabled?(user) do
          render(conn, "verify_2fa.html",
            remember_2fa_days: TwoFactor.Session.remember_2fa_days(),
            layout: {PlausibleWeb.LayoutView, "focus.html"}
          )
        else
          redirect_to_login(conn)
        end

      {:error, :not_found} ->
        redirect_to_login(conn)
    end
  end

  def verify_2fa(conn, %{"code" => code} = params) do
    with {:ok, user} <- get_2fa_user_limited(conn) do
      case Auth.TOTP.validate_code(user, code) do
        {:ok, user} ->
          conn
          |> TwoFactor.Session.maybe_set_remember_2fa(user, params["remember_2fa"])
          |> set_user_session_and_redirect(user)

        {:error, :invalid_code} ->
          maybe_log_failed_login_attempts(
            "wrong 2FA verification code provided for #{user.email}"
          )

          conn
          |> put_flash(:error, "The provided code is invalid. Please try again")
          |> render("verify_2fa.html",
            remember_2fa_days: TwoFactor.Session.remember_2fa_days(),
            layout: {PlausibleWeb.LayoutView, "focus.html"}
          )

        {:error, :not_enabled} ->
          set_user_session_and_redirect(conn, user)
      end
    end
  end

  def verify_2fa_recovery_code_form(conn, _params) do
    case TwoFactor.Session.get_2fa_user(conn) do
      {:ok, user} ->
        if Auth.TOTP.enabled?(user) do
          render(conn, "verify_2fa_recovery_code.html",
            layout: {PlausibleWeb.LayoutView, "focus.html"}
          )
        else
          redirect_to_login(conn)
        end

      {:error, :not_found} ->
        redirect_to_login(conn)
    end
  end

  def verify_2fa_recovery_code(conn, %{"recovery_code" => recovery_code}) do
    with {:ok, user} <- get_2fa_user_limited(conn) do
      case Auth.TOTP.use_recovery_code(user, recovery_code) do
        :ok ->
          set_user_session_and_redirect(conn, user)

        {:error, :invalid_code} ->
          maybe_log_failed_login_attempts("wrong 2FA recovery code provided for #{user.email}")

          conn
          |> put_flash(:error, "The provided recovery code is invalid. Please try another one")
          |> render("verify_2fa_recovery_code.html",
            layout: {PlausibleWeb.LayoutView, "focus.html"}
          )

        {:error, :not_enabled} ->
          set_user_session_and_redirect(conn, user)
      end
    end
  end

  defp get_2fa_user_limited(conn) do
    case TwoFactor.Session.get_2fa_user(conn) do
      {:ok, user} ->
        with :ok <- check_ip_rate_limit(conn),
             :ok <- check_user_rate_limit(user) do
          {:ok, user}
        else
          {:rate_limit, _} ->
            maybe_log_failed_login_attempts("too many logging attempts for #{user.email}")

            conn
            |> TwoFactor.Session.clear_2fa_user()
            |> render_error(
              429,
              "Too many login attempts. Wait a minute before trying again."
            )
        end

      {:error, :not_found} ->
        conn
        |> redirect(to: Routes.auth_path(conn, :login_form))
    end
  end

  def save_settings(conn, %{"user" => user_params}) do
    user = conn.assigns.current_user
    changes = Auth.User.settings_changeset(user, user_params)

    case Repo.update(changes) do
      {:ok, _user} ->
        conn
        |> put_flash(:success, "Account settings saved successfully")
        |> redirect(to: Routes.auth_path(conn, :user_settings))

      {:error, changeset} ->
        email_changeset = Auth.User.settings_changeset(user)

        render_settings(conn,
          settings_changeset: changeset,
          email_changeset: email_changeset
        )
    end
  end

  def update_email(conn, %{"user" => user_params}) do
    user = conn.assigns.current_user

    case RateLimit.check_rate(
           "email-change:user:#{user.id}",
           @email_change_interval,
           @email_change_limit
         ) do
      {:allow, _} ->
        changes = Auth.User.email_changeset(user, user_params)

        case Repo.update(changes) do
          {:ok, user} ->
            if user.email_verified do
              handle_email_updated(conn)
            else
              Auth.EmailVerification.issue_code(user)
              redirect(conn, to: Routes.auth_path(conn, :activate_form))
            end

          {:error, changeset} ->
            settings_changeset = Auth.User.settings_changeset(user)

            render_settings(conn,
              settings_changeset: settings_changeset,
              email_changeset: changeset
            )
        end

      {:deny, _} ->
        settings_changeset = Auth.User.settings_changeset(user)

        {:error, changeset} =
          user
          |> Auth.User.email_changeset(user_params)
          |> Ecto.Changeset.add_error(:email, "too many requests, try again in an hour")
          |> Ecto.Changeset.apply_action(:validate)

        render_settings(conn,
          settings_changeset: settings_changeset,
          email_changeset: changeset
        )
    end
  end

  def cancel_update_email(conn, _params) do
    changeset = Auth.User.cancel_email_changeset(conn.assigns.current_user)

    case Repo.update(changeset) do
      {:ok, user} ->
        conn
        |> put_flash(:success, "Email changed back to #{user.email}")
        |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#change-email-address")

      {:error, _} ->
        conn
        |> put_flash(
          :error,
          "Could not cancel email update because previous email has already been taken"
        )
        |> redirect(to: Routes.auth_path(conn, :activate_form))
    end
  end

  defp handle_email_updated(conn) do
    conn
    |> put_flash(:success, "Email updated successfully")
    |> redirect(to: Routes.auth_path(conn, :user_settings) <> "#change-email-address")
  end

  defp render_settings(conn, opts) do
    settings_changeset = Keyword.fetch!(opts, :settings_changeset)
    email_changeset = Keyword.fetch!(opts, :email_changeset)

    user = Plausible.Users.with_subscription(conn.assigns[:current_user])

    render(conn, "user_settings.html",
      user: user |> Repo.preload(:api_keys),
      settings_changeset: settings_changeset,
      email_changeset: email_changeset,
      subscription: user.subscription,
      invoices: Plausible.Billing.paddle_api().get_invoices(user.subscription),
      theme: user.theme || "system",
      team_member_limit: Quota.team_member_limit(user),
      team_member_usage: Quota.team_member_usage(user),
      site_limit: Quota.site_limit(user),
      site_usage: Quota.site_usage(user),
      pageview_limit: Quota.monthly_pageview_limit(user),
      pageview_usage: Quota.monthly_pageview_usage(user),
      totp_enabled?: Auth.TOTP.enabled?(user)
    )
  end

  def new_api_key(conn, _params) do
    changeset = Auth.ApiKey.changeset(%Auth.ApiKey{})

    render(conn, "new_api_key.html",
      changeset: changeset,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def create_api_key(conn, %{"api_key" => %{"name" => name, "key" => key}}) do
    case Auth.create_api_key(conn.assigns.current_user, name, key) do
      {:ok, _api_key} ->
        conn
        |> put_flash(:success, "API key created successfully")
        |> redirect(to: "/settings#api-keys")

      {:error, changeset} ->
        render(conn, "new_api_key.html",
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def delete_api_key(conn, %{"id" => id}) do
    case Auth.delete_api_key(conn.assigns.current_user, id) do
      :ok ->
        conn
        |> put_flash(:success, "API key revoked successfully")
        |> redirect(to: "/settings#api-keys")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Could not find API Key to delete")
        |> redirect(to: "/settings#api-keys")
    end
  end

  def delete_me(conn, params) do
    Plausible.Auth.delete_user(conn.assigns[:current_user])

    logout(conn, params)
  end

  def logout(conn, params) do
    redirect_to = Map.get(params, "redirect", "/")

    conn
    |> configure_session(drop: true)
    |> delete_resp_cookie("logged_in")
    |> redirect(to: redirect_to)
  end

  def google_auth_callback(conn, %{"error" => error, "state" => state} = params) do
    [site_id, _redirected_to, legacy, _ga4] =
      case Jason.decode!(state) do
        [site_id, redirect_to] ->
          [site_id, redirect_to, true, false]

        [site_id, redirect_to, legacy] ->
          [site_id, redirect_to, legacy, false]

        [site_id, redirect_to, legacy, ga4] ->
          [site_id, redirect_to, legacy, ga4]
      end

    site = Repo.get(Plausible.Site, site_id)

    redirect_route =
      if legacy do
        Routes.site_path(conn, :settings_integrations, site.domain)
      else
        Routes.site_path(conn, :settings_imports_exports, site.domain)
      end

    case error do
      "access_denied" ->
        conn
        |> put_flash(
          :error,
          "We were unable to authenticate your Google Analytics account. Please check that you have granted us permission to 'See and download your Google Analytics data' and try again."
        )
        |> redirect(external: redirect_route)

      message when message in ["server_error", "temporarily_unavailable"] ->
        conn
        |> put_flash(
          :error,
          "We are unable to authenticate your Google Analytics account because Google's authentication service is temporarily unavailable. Please try again in a few moments."
        )
        |> redirect(external: redirect_route)

      _any ->
        Sentry.capture_message("Google OAuth callback failed. Reason: #{inspect(params)}")

        conn
        |> put_flash(
          :error,
          "We were unable to authenticate your Google Analytics account. If the problem persists, please contact support for assistance."
        )
        |> redirect(external: redirect_route)
    end
  end

  def google_auth_callback(conn, %{"code" => code, "state" => state}) do
    res = Plausible.Google.HTTP.fetch_access_token(code)

    [site_id, redirect_to, legacy, ga4] =
      case Jason.decode!(state) do
        [site_id, redirect_to] ->
          [site_id, redirect_to, true, false]

        [site_id, redirect_to, legacy] ->
          [site_id, redirect_to, legacy, false]

        [site_id, redirect_to, legacy, ga4] ->
          [site_id, redirect_to, legacy, ga4]
      end

    site = Repo.get(Plausible.Site, site_id)
    expires_at = NaiveDateTime.add(NaiveDateTime.utc_now(), res["expires_in"])

    case redirect_to do
      "import" ->
        if ga4 do
          redirect(conn,
            external:
              Routes.site_path(conn, :import_from_ga4_property_form, site.domain,
                access_token: res["access_token"],
                refresh_token: res["refresh_token"],
                expires_at: NaiveDateTime.to_iso8601(expires_at)
              )
          )
        else
          redirect(conn,
            external:
              Routes.site_path(conn, :import_from_google_view_id_form, site.domain,
                access_token: res["access_token"],
                refresh_token: res["refresh_token"],
                expires_at: NaiveDateTime.to_iso8601(expires_at),
                legacy: legacy
              )
          )
        end

      _ ->
        id_token = res["id_token"]
        [_, body, _] = String.split(id_token, ".")
        id = body |> Base.decode64!(padding: false) |> Jason.decode!()

        Plausible.Site.GoogleAuth.changeset(%Plausible.Site.GoogleAuth{}, %{
          email: id["email"],
          refresh_token: res["refresh_token"],
          access_token: res["access_token"],
          expires: expires_at,
          user_id: conn.assigns[:current_user].id,
          site_id: site_id
        })
        |> Repo.insert!()

        site = Repo.get(Plausible.Site, site_id)

        redirect(conn, external: "/#{URI.encode_www_form(site.domain)}/settings/integrations")
    end
  end
end
