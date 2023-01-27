defmodule MainProxy.Proxy do
  @moduledoc """
  Defines a proxy

  Allows defining an http and/or https proxy.

  Basic example:

      defmodule MyApp.Proxy do
        use MainProxy.Proxy
      end

  Example with [SiteEncrypt](https://hex.pm/packages/site_encrypt):

      defmodule MyApp.Proxy do
        use MainProxy.Proxy

        @impl MainProxy.Proxy
        def merge_config(:https, opts) do
          Config.Reader.merge(opts, SiteEncrypt.https_keys(MyAppWeb.Endpoint))
        end

        def merge_config(_, opts), do: opts
      end
  """

  @type scheme :: :http | :https

  @doc """
  Merge cowboy config

  Overriding this callback allows the configuration from the application
  environment to be modified at runtime.
  """
  @callback merge_config(scheme(), keyword()) :: keyword()

  @doc """
  Specify the backends to pass requests to at startup time. (Optional)

  Overriding this callback allows for setting the backends to be matched at
  runtime when the proxy is starting up.

  Example:

      @impl MainProxy.Proxy
      def backends do
        [
          %{
            domain: "https://myapp1.com",
            phoenix_endpoint: MyApp1Web.Endpoint
          },
          %{
            domain: "https://myapp2.com",
            phoenix_endpoint: MyApp2Web.Endpoint
          }
        ]
      end
  """
  @callback backends :: list(map())

  @optional_callbacks merge_config: 2, backends: 0

  require Logger

  defmacro __using__(_opts) do
    quote do
      use Supervisor

      @behaviour MainProxy.Proxy

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl Supervisor
      def init(_opts) do
        backends = __MODULE__.backends()

        children =
          if MainProxy.Proxy.server?() do
            MainProxy.Proxy.spec([backends: backends, callback_module: __MODULE__], __MODULE__)
          else
            []
          end

        Supervisor.init(children, strategy: :one_for_one)
      end

      def merge_config(_scheme, opts), do: opts
      def backends, do: MainProxy.Proxy.default_fetch_backends()

      defoverridable merge_config: 2, backends: 0
    end
  end

  @doc false
  def default_fetch_backends do
    case Application.fetch_env(:main_proxy, :backends) do
      {:ok, backends} ->
        backends

      :error ->
        Logger.warn(
          "No backends specified. Either configure :main_proxy, :backends or define a " <>
            "`backend/0` function in your `Proxy` module."
        )
    end
  end

  # Builds the spec for each Plug.Cowboy process
  @doc false
  def spec(handler_opts, callback_module) do
    Enum.reduce([:http, :https], [], fn scheme, result ->
      case Application.get_env(:main_proxy, scheme) do
        nil ->
          # no config for this scheme, that's ok, just skip
          result

        scheme_opts ->
          backends = Keyword.fetch!(handler_opts, :backends)
          Logger.info("[main_proxy] Listening on #{scheme}")

          [{Plug.Cowboy, scheme: scheme, plug: {MainProxy.Plug, backends: backends}} | result]
      end
    end)
  end

  @doc false
  def server?() do
    # the server will be started in following situations:
    # + enable `server: true` option for main_proxy (by default)
    # + run `iex -S mix phx.server`
    # + run `mix phx.server`
    Application.get_env(:phoenix, :serve_endpoints, false) ||
      Application.get_env(:main_proxy, :server, true)
  end
end
