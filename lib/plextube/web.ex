defmodule Plextube.Web do
  use Plug.Router
  require Logger

  alias Plextube.{Download, Plex}

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:urlencoded]
  plug :dispatch

  post "/call" do
    url = conn.body_params["url"]

    case parse_youtube_url(url) do
      {:ok, video_id} ->
        video_file = download_and_add(video_id)
        send_json(conn, 200, id: video_id, file: video_file)

      {:nomatch, msg} ->
        send_json(conn, 404, error: msg)
    end
  end

  defp send_json(conn, code, data) do
    data = [{:success, code == 200} | data]
    send_resp(conn, code, data |> Map.new |> Poison.encode!)
  end

  match _ do
    send_json(conn, 404, error: "Not found")
  end

  defp parse_youtube_url(nil), do: {:nomatch, "No URL supplied."}
  defp parse_youtube_url(url) do
    URI.parse(url)
    |> parse_youtube_uri
  end

  defp parse_youtube_uri(%URI{host: "youtu.be"} = uri) do
    uri.path
    |> String.trim_leading("/")
    |> check_youtube_id
  end
  defp parse_youtube_uri(%URI{query: query}) do
    query
    |> URI.decode_query
    |> Map.get("v", nil)
    |> check_youtube_id
  end
  defp parse_youtube_uri(_), do: {:nomatch, "URL not recognised."}

  defp check_youtube_id(nil), do: {:nomatch, "Can't get a video ID."}
  defp check_youtube_id(id) do
    if id =~ ~r{^[A-Za-z0-9_-]+$} do
      {:ok, id}
    else
      {:nomatch, "Not a valid video ID: #{inspect(id)}"}
    end
  end

  defp download_and_add(id) do
    {:ok, path} = Briefly.create(directory: true)

    %{output_file: file} = Download.youtube_dl(id, path)
    move_to_library(path, file)
    refresh_plex()

    file
  end

  defp move_to_library(path, file) do
    source = Path.join(path, file)
    target = Path.join(library_path(), file)

    case File.rename(source, target) do
      :ok -> :ok
      {:error, :exdev} ->
        Logger.warn("Temporary directory and library are on different devices; falling back to copy.")
        File.cp!(source, target)
    end
  end

  defp library_path do
    path = Application.get_env(:plextube, :library_path)
    if is_nil(path) || path == "/path/to/write/videos/to", do: raise "Must set :library_path in config/plextube.exs"
    path
  end

  defp refresh_plex do
    path = library_path()
    path
    |> Plex.section_for_path
    |> scan_plex_section(path)
  end

  def scan_plex_section(%{"key" => key}, _), do: Plex.scan_section(key)
  def scan_plex_section(nil, path) do
    Logger.warn("Can't find a Plex library for #{inspect(path)}, refreshing all libraries.")
    Plex.scan_section("all")
  end
end
