defmodule AshStorage.BlobIO.Operation do
  @moduledoc false
  # Namespace for the shared structs embedded in the per-phase `*.Operation`
  # payloads: ServiceState, BlobDraft, CreateParams. Not itself a phase
  # operation (those are Reader.Operation, Writer.Operation, etc.); the
  # embedded structs carry their own docs.

  defmodule ServiceState do
    @moduledoc """
    Storage service state carried by BlobIO phase operations.

    `opts` are the mutable service options. `context` is rebuilt from those
    options when crossing the storage adapter boundary.
    """

    alias AshStorage.Service

    defstruct [:mod, :context, opts: []]

    @type t :: %__MODULE__{
            mod: module() | nil,
            context: Service.Context.t() | nil,
            opts: keyword()
          }

    @doc "Build service state from a resolved storage service pair."
    def new(mod, opts) when is_list(opts), do: %__MODULE__{mod: mod, opts: opts}
  end

  defmodule BlobDraft do
    @moduledoc """
    Draft blob-row attributes carried by write and direct-upload operations.

    These fields may be adjusted before BlobIO persists the blob record.
    """

    defstruct [
      :key,
      :filename,
      :content_type,
      :checksum,
      :byte_size,
      attrs: %{},
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            filename: String.t(),
            content_type: String.t(),
            checksum: String.t() | nil,
            byte_size: non_neg_integer() | nil,
            attrs: map(),
            metadata: map()
          }

    @doc "Build draft blob attributes from public BlobIO call options."
    def new(opts) when is_list(opts) do
      %__MODULE__{
        key: Keyword.get_lazy(opts, :key, &AshStorage.generate_key/0),
        filename: Keyword.fetch!(opts, :filename),
        content_type: Keyword.get(opts, :content_type, "application/octet-stream"),
        checksum: Keyword.get(opts, :checksum),
        byte_size: Keyword.get(opts, :byte_size),
        attrs: Keyword.get(opts, :blob_attrs, %{}),
        metadata: Keyword.get(opts, :metadata, %{})
      }
    end
  end

  defmodule CreateParams do
    @moduledoc """
    Framework-owned `Ash.create` binding carried on a write operation (`action`
    plus `ash_opts`).

    Part of the write operation's shape — the writer owns it to persist the
    blob row.
    """

    defstruct action: :create, ash_opts: []

    @type t :: %__MODULE__{
            action: atom(),
            ash_opts: keyword()
          }
  end
end
