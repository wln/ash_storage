defmodule AshStorage.BlobIO.DirectUploads do
  @moduledoc false
  # BlobIO direct-upload preparation phase: create a pending blob row and ask the
  # service for client-side upload instructions. Internal.

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Operation.{BlobDraft, ServiceState}
  alias AshStorage.BlobIO.Support
  alias AshStorage.Info

  defmodule Operation do
    @moduledoc """
    Phase-local state for direct-upload preparation.

    The operation contains the future blob attributes plus the service context
    that will be used to request upload instructions from the adapter. The bytes
    never pass through the server on a direct upload — they stream client →
    service.
    """

    defstruct [
      :blob_context,
      :draft,
      :service,
      ash_opts: [],
      call_opts: []
    ]

    @typedoc "Mutable operation payload for direct-upload preparation."
    @type t :: %__MODULE__{
            blob_context: BlobContext.t(),
            draft: BlobDraft.t(),
            service: ServiceState.t(),
            ash_opts: keyword(),
            call_opts: keyword()
          }
  end

  @doc """
  Create a pending blob and return service-specific direct-upload information.
  """
  def prepare(%BlobContext{} = bctx, opts) when is_list(opts) do
    with {:ok, {service_mod, service_opts}} <- Support.resolve_service(bctx, opts) do
      operation =
        %Operation{
          blob_context: bctx,
          draft: %BlobDraft{
            key: Keyword.get_lazy(opts, :key, &AshStorage.generate_key/0),
            filename: Keyword.fetch!(opts, :filename),
            content_type: Keyword.get(opts, :content_type, "application/octet-stream"),
            byte_size: Keyword.get(opts, :byte_size, 0),
            checksum: Keyword.get(opts, :checksum, ""),
            metadata: Keyword.get(opts, :metadata, %{})
          },
          ash_opts: Keyword.get(opts, :ash_opts, []),
          call_opts: opts,
          service: ServiceState.new(service_mod, service_opts)
        }
        |> Support.put_service_context()

      with blob_resource = Info.storage_blob_resource!(operation.blob_context.resource),
           {:ok, blob} <-
             Ash.create(
               blob_resource,
               %{
                 key: operation.draft.key,
                 filename: operation.draft.filename,
                 content_type: operation.draft.content_type,
                 byte_size: operation.draft.byte_size,
                 checksum: operation.draft.checksum,
                 service_name: operation.service.mod,
                 service_opts:
                   Support.persistable_service_opts(
                     operation.service.mod,
                     operation.service.opts
                   ),
                 metadata: operation.draft.metadata
               },
               Keyword.merge(operation.ash_opts, action: :create)
             ),
           {:ok, upload_info} <-
             operation.service.mod.direct_upload(operation.draft.key, operation.service.context) do
        {:ok, Map.put(upload_info, :blob, blob)}
      end
    end
  end
end
