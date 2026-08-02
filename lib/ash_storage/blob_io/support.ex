defmodule AshStorage.BlobIO.Support do
  @moduledoc false
  # Shared internal helpers for the BlobIO phase modules: service resolution,
  # BlobContext -> Service.Context projection, and input/upload normalization.
  # Phase policy stays in the phase modules; helpers here only convert data
  # shapes or preserve existing service/Ash errors.

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Operation.ServiceState
  alias AshStorage.Info
  alias AshStorage.Service.Context

  @doc """
  Rebuild the service context for an operation from its current BlobIO context.
  """
  def put_service_context(
        %{blob_context: %BlobContext{}, service: %ServiceState{} = service} = operation
      ) do
    service_ctx =
      operation.blob_context
      |> BlobContext.to_service_context(service.opts)
      |> maybe_put_expected_md5(operation)
      |> put_blob_metadata(operation)

    %{operation | service: %{service | context: service_ctx}}
  end

  @doc """
  Resolve a service for forgiving serving operations.

  Serving uses `:not_servable`/`nil` instead of returning service-resolution
  errors, so this helper converts a failed strict resolution into `{nil, []}`.
  """
  def service_for_operation(bctx, opts) do
    case resolve_service(bctx, opts) do
      {:ok, service} -> service
      {:error, _reason} -> {nil, []}
    end
  end

  @doc """
  Resolve the storage service for strict BlobIO operations.

  An explicit `:service` option wins. Otherwise the service is looked up from
  `bctx.resource` and `bctx.attachment`. Missing configuration returns
  `{:error, :no_service_configured}`.
  """
  def resolve_service(bctx, opts) do
    case Keyword.fetch(opts, :service) do
      {:ok, {service_mod, service_opts}} -> {:ok, {service_mod, service_opts}}
      :error -> resolve_service_from_context(bctx)
    end
  end

  @doc """
  Return the subset of service options that should be persisted on a blob.

  Services opt into persistence by implementing `service_opts_fields/0`; those
  fields are later reconstituted by the blob's `:parsed_service_opts`
  calculation for async/read flows.
  """
  def persistable_service_opts(service_mod, service_opts) do
    if function_exported?(service_mod, :service_opts_fields, 0) do
      fields = service_mod.service_opts_fields()
      field_names = Keyword.keys(fields)

      service_opts
      |> Keyword.take(field_names)
      |> Map.new()
    else
      %{}
    end
  end

  @doc "Materialize accepted BlobIO write inputs into a binary."
  def input_to_binary(%Ash.Type.File{} = file) do
    {:ok, device} = Ash.Type.File.open(file, [:read, :binary])
    data = IO.binread(device, :eof)
    File.close(device)
    data
  end

  def input_to_binary(%File.Stream{} = stream),
    do: Enum.into(stream, <<>>, &IO.iodata_to_binary/1)

  # A Plug.Upload from a controller: read the file from its `:path` rather than
  # letting the path string fall through to the binary clause and be stored as
  # the body. Matched structurally so Plug stays an optional dependency.
  #
  # `path` is Plug's server-generated multipart temp file (`%Plug.Upload{}.path`),
  # not a client-controlled path: the caller controls the file's bytes and declared
  # filename, never where Plug writes it, so this `File.read!` is not a traversal
  # vector.
  # sobelow_skip ["Traversal.FileModule"]
  def input_to_binary(%{__struct__: Plug.Upload, path: path}) when is_binary(path),
    do: File.read!(path)

  def input_to_binary(data) when is_binary(data), do: data
  def input_to_binary(data) when is_list(data), do: IO.iodata_to_binary(data)

  @doc """
  Normalize adapter upload return values into extra blob attributes.

  The service callback may return `:ok`, `{:ok, attrs}`, or `{:error, reason}`.
  BlobIO stores `attrs` on the blob record after a successful upload.
  """
  def normalize_upload(:ok), do: {:ok, %{}}
  def normalize_upload({:ok, attrs}) when is_map(attrs), do: {:ok, attrs}
  def normalize_upload({:error, _} = error), do: error

  defp maybe_put_expected_md5(%Context{} = ctx, operation) do
    Context.put_expected_md5(ctx, expected_md5(operation))
  end

  defp expected_md5(%{draft: %{checksum: checksum}}) when is_binary(checksum) and checksum != "",
    do: checksum

  defp expected_md5(%{blob: %{checksum: checksum}}) when is_binary(checksum) and checksum != "",
    do: checksum

  defp expected_md5(_operation), do: nil

  # Forward the blob's content_type/filename onto the service context so adapters
  # can set them on the stored object (e.g. the `Content-Type` header on a PUT).
  # Drawn from the write draft when present, otherwise the persisted blob.
  defp put_blob_metadata(%Context{} = ctx, operation) do
    Context.put_blob_metadata(ctx,
      content_type: blob_metadata(operation, :content_type),
      filename: blob_metadata(operation, :filename)
    )
  end

  defp blob_metadata(%{draft: %{content_type: ct}}, :content_type)
       when is_binary(ct) and ct != "",
       do: ct

  defp blob_metadata(%{blob: %{content_type: ct}}, :content_type)
       when is_binary(ct) and ct != "",
       do: ct

  defp blob_metadata(%{draft: %{filename: name}}, :filename)
       when is_binary(name) and name != "",
       do: name

  defp blob_metadata(%{blob: %{filename: name}}, :filename)
       when is_binary(name) and name != "",
       do: name

  defp blob_metadata(_operation, _key), do: nil

  defp resolve_service_from_context(%BlobContext{resource: resource, attachment: attachment})
       when not is_nil(resource) and not is_nil(attachment) do
    case Info.service_for_attachment(resource, attachment) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
  end

  defp resolve_service_from_context(_bctx), do: {:error, :no_service_configured}
end
