defmodule PlausibleWeb.Router do
  use PlausibleWeb, :router
  use Plausible
  import Phoenix.LiveView.Router
  @two_weeks_in_seconds 60 * 60 * 24 * 14

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
    plug PlausibleWeb.Plugs.NoRobots
    on_full_build(do: nil, else: plug(PlausibleWeb.FirstLaunchPlug, redirect_to: "/register"))
    plug PlausibleWeb.SessionTimeoutPlug, timeout_after_seconds: @two_weeks_in_seconds
    plug PlausibleWeb.AuthPlug
    plug PlausibleWeb.LastSeenPlug
  end

  pipeline :shared_link do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
    plug PlausibleWeb.Plugs.NoRobots
  end

  pipeline :csrf do
    plug :protect_from_forgery
  end

  pipeline :focus_layout do
    plug :put_root_layout, html: {PlausibleWeb.LayoutView, :focus}
  end

  pipeline :app_layout do
    plug :put_root_layout, html: {PlausibleWeb.LayoutView, :app}
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug PlausibleWeb.AuthPlug
  end

  pipeline :internal_stats_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug PlausibleWeb.AuthorizeSiteAccess
    plug PlausibleWeb.Plugs.NoRobots
  end

  pipeline :public_api do
    plug :accepts, ["json"]
  end

  on_full_build do
    pipeline :flags do
      plug :accepts, ["html"]
      plug :put_secure_browser_headers
      plug PlausibleWeb.Plugs.NoRobots
      plug :fetch_session

      plug PlausibleWeb.CRMAuthPlug
    end
  end

  if Mix.env() == :dev do
    forward "/sent-emails", Bamboo.SentEmailViewerPlug
  end

  on_full_build do
    use Kaffy.Routes,
      scope: "/crm",
      pipe_through: [PlausibleWeb.Plugs.NoRobots, PlausibleWeb.CRMAuthPlug]
  end

  on_full_build do
    scope "/crm", PlausibleWeb do
      pipe_through :flags
      get "/auth/user/:user_id/usage", AdminController, :usage
    end
  end

  on_full_build do
    scope path: "/flags" do
      pipe_through :flags
      forward "/", FunWithFlags.UI.Router, namespace: "flags"
    end
  end

  scope path: "/api/plugins", as: :plugins_api do
    pipeline :plugins_api_auth do
      plug(PlausibleWeb.Plugs.AuthorizePluginsAPI)
    end

    pipeline :plugins_api do
      plug(:accepts, ["json"])
      plug(OpenApiSpex.Plug.PutApiSpec, module: PlausibleWeb.Plugins.API.Spec)
    end

    scope "/spec" do
      pipe_through(:plugins_api)
      get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
      get("/swagger-ui", OpenApiSpex.Plug.SwaggerUI, path: "/api/plugins/spec/openapi")
    end

    scope "/v1/capabilities", PlausibleWeb.Plugins.API.Controllers, assigns: %{plugins_api: true} do
      pipe_through([:plugins_api])
      get("/", Capabilities, :index)
    end

    scope "/v1", PlausibleWeb.Plugins.API.Controllers, assigns: %{plugins_api: true} do
      pipe_through([:plugins_api, :plugins_api_auth])

      get("/shared_links", SharedLinks, :index)
      get("/shared_links/:id", SharedLinks, :get)
      put("/shared_links", SharedLinks, :create)

      get("/goals", Goals, :index)
      get("/goals/:id", Goals, :get)
      put("/goals", Goals, :create)

      delete("/goals/:id", Goals, :delete)
      delete("/goals", Goals, :delete_bulk)

      put("/custom_props", CustomProps, :enable)
      delete("/custom_props", CustomProps, :disable)
    end
  end

  scope "/api/stats", PlausibleWeb.Api do
    pipe_through :internal_stats_api

    on_full_build do
      get "/:domain/funnels/:id", StatsController, :funnel
    end

    get "/:domain/current-visitors", StatsController, :current_visitors
    get "/:domain/main-graph", StatsController, :main_graph
    get "/:domain/top-stats", StatsController, :top_stats
    get "/:domain/sources", StatsController, :sources
    get "/:domain/utm_mediums", StatsController, :utm_mediums
    get "/:domain/utm_sources", StatsController, :utm_sources
    get "/:domain/utm_campaigns", StatsController, :utm_campaigns
    get "/:domain/utm_contents", StatsController, :utm_contents
    get "/:domain/utm_terms", StatsController, :utm_terms
    get "/:domain/referrers/:referrer", StatsController, :referrer_drilldown
    get "/:domain/pages", StatsController, :pages
    get "/:domain/entry-pages", StatsController, :entry_pages
    get "/:domain/exit-pages", StatsController, :exit_pages
    get "/:domain/countries", StatsController, :countries
    get "/:domain/regions", StatsController, :regions
    get "/:domain/cities", StatsController, :cities
    get "/:domain/browsers", StatsController, :browsers
    get "/:domain/browser-versions", StatsController, :browser_versions
    get "/:domain/operating-systems", StatsController, :operating_systems
    get "/:domain/operating-system-versions", StatsController, :operating_system_versions
    get "/:domain/screen-sizes", StatsController, :screen_sizes
    get "/:domain/conversions", StatsController, :conversions
    get "/:domain/custom-prop-values/:prop_key", StatsController, :custom_prop_values
    get "/:domain/suggestions/:filter_name", StatsController, :filter_suggestions
  end

  scope "/api/v1/stats", PlausibleWeb.Api do
    pipe_through [:public_api, PlausibleWeb.AuthorizeStatsApiPlug]

    get "/realtime/visitors", ExternalStatsController, :realtime_visitors
    get "/aggregate", ExternalStatsController, :aggregate
    get "/breakdown", ExternalStatsController, :breakdown
    get "/timeseries", ExternalStatsController, :timeseries
  end

  on_full_build do
    scope "/api/v1/sites", PlausibleWeb.Api do
      pipe_through [:public_api, PlausibleWeb.AuthorizeSitesApiPlug]

      post "/", ExternalSitesController, :create_site
      put "/shared-links", ExternalSitesController, :find_or_create_shared_link
      put "/goals", ExternalSitesController, :find_or_create_goal
      delete "/goals/:goal_id", ExternalSitesController, :delete_goal
      get "/:site_id", ExternalSitesController, :get_site
      put "/:site_id", ExternalSitesController, :update_site
      delete "/:site_id", ExternalSitesController, :delete_site
    end
  end

  scope "/api", PlausibleWeb do
    pipe_through :api

    post "/event", Api.ExternalController, :event
    get "/error", Api.ExternalController, :error
    get "/health", Api.ExternalController, :health
    get "/system", Api.ExternalController, :info

    post "/paddle/webhook", Api.PaddleController, :webhook

    get "/:domain/status", Api.InternalController, :domain_status
    put "/:domain/disable-feature", Api.InternalController, :disable_feature

    get "/sites", Api.InternalController, :sites
  end

  scope "/", PlausibleWeb do
    pipe_through [:browser, :csrf]

    scope alias: Live, assigns: %{connect_live_socket: true} do
      pipe_through [PlausibleWeb.RequireLoggedOutPlug, :focus_layout]

      scope assigns: %{disable_registration_for: [:invite_only, true]} do
        pipe_through PlausibleWeb.Plugs.MaybeDisableRegistration

        live "/register", RegisterForm, :register_form, as: :auth
      end

      scope assigns: %{
              disable_registration_for: true,
              dogfood_page_path: "/register/invitation/:invitation_id"
            } do
        pipe_through PlausibleWeb.Plugs.MaybeDisableRegistration

        live "/register/invitation/:invitation_id", RegisterForm, :register_from_invitation_form,
          as: :auth
      end
    end

    post "/register", AuthController, :register
    post "/register/invitation/:invitation_id", AuthController, :register_from_invitation
    get "/activate", AuthController, :activate_form
    post "/activate/request-code", AuthController, :request_activation_code
    post "/activate", AuthController, :activate
    get "/login", AuthController, :login_form
    post "/login", AuthController, :login
    get "/password/request-reset", AuthController, :password_reset_request_form
    post "/password/request-reset", AuthController, :password_reset_request
    post "/2fa/setup/initiate", AuthController, :initiate_2fa_setup
    get "/2fa/setup/verify", AuthController, :verify_2fa_setup_form
    post "/2fa/setup/verify", AuthController, :verify_2fa_setup
    post "/2fa/disable", AuthController, :disable_2fa
    post "/2fa/recovery_codes", AuthController, :generate_2fa_recovery_codes
    get "/2fa/verify", AuthController, :verify_2fa_form
    post "/2fa/verify", AuthController, :verify_2fa
    get "/2fa/use_recovery_code", AuthController, :verify_2fa_recovery_code_form
    post "/2fa/use_recovery_code", AuthController, :verify_2fa_recovery_code
    get "/password/reset", AuthController, :password_reset_form
    post "/password/reset", AuthController, :password_reset
    get "/avatar/:hash", AvatarController, :avatar
    post "/error_report", ErrorReportController, :submit_error_report
  end

  scope "/", PlausibleWeb do
    pipe_through [:shared_link]

    get "/share/:domain", StatsController, :shared_link
    post "/share/:slug/authenticate", StatsController, :authenticate_shared_link
  end

  scope "/", PlausibleWeb do
    pipe_through [:browser, :csrf]

    get "/logout", AuthController, :logout
    get "/settings", AuthController, :user_settings
    put "/settings", AuthController, :save_settings
    put "/settings/email", AuthController, :update_email
    post "/settings/email/cancel", AuthController, :cancel_update_email
    delete "/me", AuthController, :delete_me
    get "/settings/api-keys/new", AuthController, :new_api_key
    post "/settings/api-keys", AuthController, :create_api_key
    delete "/settings/api-keys/:id", AuthController, :delete_api_key

    get "/auth/google/callback", AuthController, :google_auth_callback

    get "/", PageController, :index

    get "/billing/change-plan/preview/:plan_id", BillingController, :change_plan_preview
    post "/billing/change-plan/:new_plan_id", BillingController, :change_plan
    get "/billing/choose-plan", BillingController, :choose_plan
    get "/billing/upgrade-to-enterprise-plan", BillingController, :upgrade_to_enterprise_plan
    get "/billing/upgrade-success", BillingController, :upgrade_success
    get "/billing/subscription/ping", BillingController, :ping_subscription

    scope alias: Live, assigns: %{connect_live_socket: true} do
      pipe_through [:app_layout, PlausibleWeb.RequireAccountPlug]

      live "/sites", Sites, :index, as: :site
    end

    get "/sites/new", SiteController, :new
    post "/sites", SiteController, :create_site
    get "/sites/:website/change-domain", SiteController, :change_domain
    put "/sites/:website/change-domain", SiteController, :change_domain_submit
    get "/:website/change-domain-snippet", SiteController, :add_snippet_after_domain_change
    post "/sites/:website/make-public", SiteController, :make_public
    post "/sites/:website/make-private", SiteController, :make_private
    post "/sites/:website/weekly-report/enable", SiteController, :enable_weekly_report
    post "/sites/:website/weekly-report/disable", SiteController, :disable_weekly_report
    post "/sites/:website/weekly-report/recipients", SiteController, :add_weekly_report_recipient

    delete "/sites/:website/weekly-report/recipients/:recipient",
           SiteController,
           :remove_weekly_report_recipient

    post "/sites/:website/monthly-report/enable", SiteController, :enable_monthly_report
    post "/sites/:website/monthly-report/disable", SiteController, :disable_monthly_report

    post "/sites/:website/monthly-report/recipients",
         SiteController,
         :add_monthly_report_recipient

    delete "/sites/:website/monthly-report/recipients/:recipient",
           SiteController,
           :remove_monthly_report_recipient

    post "/sites/:website/spike-notification/enable", SiteController, :enable_spike_notification
    post "/sites/:website/spike-notification/disable", SiteController, :disable_spike_notification
    put "/sites/:website/spike-notification", SiteController, :update_spike_notification

    post "/sites/:website/spike-notification/recipients",
         SiteController,
         :add_spike_notification_recipient

    delete "/sites/:website/spike-notification/recipients/:recipient",
           SiteController,
           :remove_spike_notification_recipient

    get "/sites/:website/shared-links/new", SiteController, :new_shared_link
    post "/sites/:website/shared-links", SiteController, :create_shared_link
    get "/sites/:website/shared-links/:slug/edit", SiteController, :edit_shared_link
    put "/sites/:website/shared-links/:slug", SiteController, :update_shared_link
    delete "/sites/:website/shared-links/:slug", SiteController, :delete_shared_link

    get "/sites/:website/memberships/invite", Site.MembershipController, :invite_member_form
    post "/sites/:website/memberships/invite", Site.MembershipController, :invite_member

    post "/sites/invitations/:invitation_id/accept", InvitationController, :accept_invitation

    post "/sites/invitations/:invitation_id/reject", InvitationController, :reject_invitation

    delete "/sites/:website/invitations/:invitation_id", InvitationController, :remove_invitation

    get "/sites/:website/transfer-ownership", Site.MembershipController, :transfer_ownership_form
    post "/sites/:website/transfer-ownership", Site.MembershipController, :transfer_ownership

    put "/sites/:website/memberships/:id/role/:new_role", Site.MembershipController, :update_role
    delete "/sites/:website/memberships/:id", Site.MembershipController, :remove_member

    get "/sites/:website/weekly-report/unsubscribe", UnsubscribeController, :weekly_report
    get "/sites/:website/monthly-report/unsubscribe", UnsubscribeController, :monthly_report

    get "/:website/snippet", SiteController, :add_snippet
    get "/:website/settings", SiteController, :settings
    get "/:website/settings/general", SiteController, :settings_general
    get "/:website/settings/people", SiteController, :settings_people
    get "/:website/settings/visibility", SiteController, :settings_visibility
    get "/:website/settings/goals", SiteController, :settings_goals
    get "/:website/settings/properties", SiteController, :settings_props

    on_full_build do
      get "/:website/settings/funnels", SiteController, :settings_funnels
    end

    get "/:website/settings/email-reports", SiteController, :settings_email_reports
    get "/:website/settings/danger-zone", SiteController, :settings_danger_zone
    get "/:website/settings/integrations", SiteController, :settings_integrations
    get "/:website/settings/shields/:shield", SiteController, :settings_shields
    get "/:website/settings/imports-exports", SiteController, :settings_imports_exports

    put "/:website/settings/features/visibility/:setting",
        SiteController,
        :update_feature_visibility

    put "/:website/settings", SiteController, :update_settings
    put "/:website/settings/google", SiteController, :update_google_auth
    delete "/:website/settings/google-search", SiteController, :delete_google_auth
    delete "/:website/settings/google-import", SiteController, :delete_google_auth
    delete "/:website", SiteController, :delete_site
    delete "/:website/stats", SiteController, :reset_stats

    get "/:website/import/google-analytics/view-id",
        SiteController,
        :import_from_google_view_id_form

    post "/:website/import/google-analytics/view-id", SiteController, :import_from_google_view_id

    get "/:website/import/google-analytics/user-metric",
        SiteController,
        :import_from_google_user_metric_notice

    get "/:website/import/google-analytics/confirm", SiteController, :import_from_google_confirm
    post "/:website/settings/google-import", SiteController, :import_from_google

    get "/:website/import/google-analytics4/property",
        SiteController,
        :import_from_ga4_property_form

    post "/:website/import/google-analytics4/property", SiteController, :import_from_ga4_property

    get "/:website/import/google-analytics4/confirm", SiteController, :import_from_ga4_confirm
    post "/:website/settings/google4-import", SiteController, :import_from_ga4

    delete "/:website/settings/forget-imported", SiteController, :forget_imported
    delete "/:website/settings/forget-import/:import_id", SiteController, :forget_import

    get "/:domain/export", StatsController, :csv_export
    get "/:domain/*path", StatsController, :stats
  end
end
