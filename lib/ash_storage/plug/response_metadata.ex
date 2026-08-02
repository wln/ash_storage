defmodule AshStorage.Plug.ResponseMetadata do
  @moduledoc """
  Resolves response metadata for AshStorage serving plugs.

  Storage keys are sometimes opaque or transformed, so blob-aware serving should
  prefer durable blob metadata before falling back to path suffixes. Query
  parameters remain presentation hints for `Content-Disposition`; they are not
  treated as authoritative MIME metadata.
  """

  @generic_content_types [nil, "", "application/octet-stream", "binary/octet-stream"]

  @doc """
  Resolve the `Content-Type` header for a response.

  Meaningful blob `content_type` values win. Otherwise, blob filename suffixes
  are used when a blob is available, then the storage key/path suffix, then the
  configured fallback.
  """
  def content_type(path, opts \\ []) do
    blob = Keyword.get(opts, :blob)
    fallback = Keyword.get(opts, :fallback, "application/octet-stream")

    cond do
      meaningful_content_type?(blob_content_type(blob)) ->
        blob_content_type(blob)

      content_type = path_content_type(blob_filename(blob)) ->
        content_type

      content_type = path_content_type(path) ->
        content_type

      true ->
        fallback
    end
  end

  @doc """
  Add a `Content-Disposition` header.

  Defaults to `attachment` so that caller-influenced `content_type` (e.g.
  `text/html`, `image/svg+xml`) cannot be rendered inline through the
  application origin — a stored-XSS vector. `inline` is honored ONLY when the
  route opts into it via `allowed_dispositions` AND the request asks for it;
  it is never the default. The `filename` query parameter is a presentation
  hint only, falling back to `blob.filename`.
  """
  def put_content_disposition(conn, opts \\ []) do
    params = Plug.Conn.fetch_query_params(conn).query_params
    allowed = Keyword.get(opts, :allowed_dispositions, ["attachment"])
    blob = Keyword.get(opts, :blob)
    filename = params["filename"] || blob_filename(blob)

    requested = params["disposition"]

    disposition =
      if is_binary(requested) and requested in allowed do
        requested
      else
        "attachment"
      end

    Plug.Conn.put_resp_header(
      conn,
      "content-disposition",
      disposition(disposition, filename)
    )
  end

  @doc """
  Set `X-Content-Type-Options: nosniff` so intermediaries/browsers do not
  MIME-sniff a response into an active content type.
  """
  def put_nosniff(conn) do
    Plug.Conn.put_resp_header(conn, "x-content-type-options", "nosniff")
  end

  defp meaningful_content_type?(content_type), do: content_type not in @generic_content_types

  defp path_content_type(path) when is_binary(path) and path != "", do: MIME.from_path(path)
  defp path_content_type(_path), do: nil

  defp blob_content_type(blob) when is_map(blob), do: Map.get(blob, :content_type)
  defp blob_content_type(_blob), do: nil

  defp blob_filename(blob) when is_map(blob), do: Map.get(blob, :filename)
  defp blob_filename(_blob), do: nil

  defp disposition(disposition, filename) when is_binary(filename) and filename != "" do
    ~s(#{disposition}; filename="#{safe_filename(filename)}")
  end

  defp disposition(disposition, _filename), do: disposition

  defp safe_filename(filename) do
    String.replace(filename, ~r/[\r\n"]/, "_")
  end
end
