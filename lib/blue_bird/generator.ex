defmodule BlueBird.Generator do
  require Logger

  alias BlueBird.ConnLogger
  alias Mix.Project
  alias Phoenix.Naming
  alias Phoenix.Router.Route

  @default_url "http://localhost"
  @default_title "API Documentation"
  @default_description "Enter API description in mix.exs - blue_bird_info"

  # todo: documentation
  # todo: make more functions public for easier testing
  # todo: define api_doc struct?

  @spec run :: map
  def run do
    get_app_module()
    |> get_router_module()
    |> prepare_docs()
  end

  @spec get_app_module :: atom
  def get_app_module do
    Project.get.application
    |> Keyword.get(:mod)
    |> elem(0)
  end

  @spec get_router_module(atom) :: atom
  def get_router_module(app_module) do
    Application.get_env(
      :blue_bird,
      :router,
      Module.concat([app_module, :Router])
    )
  end

  @spec prepare_docs(atom) :: map
  defp prepare_docs(router_module) do
    info = blue_bird_info()

    %{
      host: Keyword.get(info, :host, @default_url),
      title: Keyword.get(info, :title, @default_title),
      description: Keyword.get(info, :description, @default_description),
      routes: generate_docs_for_routes(router_module)
    }
  end

  @spec blue_bird_info :: [String.t]
  defp blue_bird_info do
    case function_exported?(Project.get, :blue_bird_info, 0) do
      true  -> Project.get.blue_bird_info() # todo: is this testable?
      false -> []
    end
  end

  @spec generate_docs_for_routes(atom) :: [map]
  defp generate_docs_for_routes(router_module) do
    routes = filter_api_routes(router_module.__routes__)

    ConnLogger.get_conns()
    |> requests(routes)
    |> process_routes(routes)
  end

  @spec filter_api_routes([map]) :: [map]
  defp filter_api_routes(routes) do
    Enum.filter(routes, &Enum.member?(&1.pipe_through, :api))
  end

  @spec requests([%Plug.Conn{}], [map]) :: [%Plug.Conn{}]
  defp requests(test_conns, routes) do
    Enum.reduce(test_conns, [], fn(conn, list) ->
      case find_route(routes, conn.request_path) do
        # todo: nil impossible? or possible if plug catches
        # Phoenix.Router.NoRouteError? how to test?
        nil   -> list
        route -> [request_map(route, conn) | list]
      end
    end)
  end

  @spec find_route([%Route{}], String.t) ::
    %Route{} | nil
  defp find_route(routes, path) do
    routes
    |> Enum.sort_by(fn(route) -> -byte_size(route.path) end)
    |> Enum.find(fn(route) -> route_match?(route.path, path) end)
  end

  @spec route_match?(String.t, String.t) :: boolean
  defp route_match?(route, path) do
    ~r/(:[^\/]+)/
    |> Regex.replace(route, "([^/]+)")
    |> Regex.compile!()
    |> Regex.match?(path)
  end

  @spec request_map(map, %Plug.Conn{}) :: map
  defp request_map(route, conn) do
    %{
      method: conn.method,
      path: route.path,
      headers: conn.req_headers,
      path_params: conn.path_params,
      body_params: conn.body_params,
      query_params: conn.query_params,
      response: %{
        status: conn.status,
        body: conn.resp_body,
        headers: conn.resp_headers
      }
    }
  end

  @spec process_routes([map], [%Route{}]) :: [map]
  defp process_routes(requests_list, routes) do
    routes
    |> Enum.reduce([], fn(route, generate_docs_for_routes) ->
         case process_route(route, requests_list) do
           {:ok, route_doc} -> [route_doc | generate_docs_for_routes]
           _                -> generate_docs_for_routes
         end
       end)
    |> Enum.reverse()
  end

  @spec process_route(%Route{}, [map]) :: {:ok, map} | :error
  defp process_route(route, requests) do
    controller = Module.concat([:Elixir | Module.split(route.plug)])
    method     = route.verb |> Atom.to_string |> String.upcase

    route_requests = Enum.filter(requests, fn(request) ->
      request.method == method and request.path == route.path
    end)

    try do
      route_docs = controller
        |> apply(:api_doc, [method, route.path])
        |> set_default(route, :group)
        |> set_default(route, :resource)
        |> Map.put(:requests, route_requests)

      {:ok, route_docs}
    rescue
      UndefinedFunctionError ->
        Logger.warn fn -> "No api doc defined for #{method} #{route.path}." end
        :error
      FunctionClauseError ->
        Logger.warn fn -> "No api doc defined for #{method} #{route.path}." end
        :error
    end
  end

  @spec set_default(map, %Route{}, atom) :: map
  defp set_default(%{group: nil} = route_docs, route, :group) do
    set_default_to_controller(route_docs, route, :group)
  end
  defp set_default(%{resource: nil} = route_docs, route, :resource) do
    set_default_to_controller(route_docs, route, :resource)
  end
  defp set_default(route_docs, _, _), do: route_docs

  @spec set_default_to_controller(map, %Route{}, atom) :: map
  defp set_default_to_controller(route_docs, route, key) do
    value = route.plug
    |> Naming.resource_name("Controller")
    |> Naming.humanize

    Map.put(route_docs, key, value)
  end
end
