defmodule AshStorage.Service.S3Test do
  # Mutates application config; keep it out of the async pool.
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Service.S3
  alias AshStorage.Test.{Blob, ConfigurablePost}

  setup do
    # Inline credentials are the configuration shape this fix is about. The
    # SigV4 presign is computed locally, so no network is involved.
    Application.put_env(:ash_storage, ConfigurablePost,
      storage: [
        service:
          {S3,
           bucket: "test-bucket",
           region: "us-east-1",
           access_key_id: "AKIAINLINEEXAMPLE",
           secret_access_key: "inline-secret-must-not-persist"}
      ]
    )

    on_exit(fn -> Application.delete_env(:ash_storage, ConfigurablePost) end)
  end

  describe "credentials never round-trip onto the blob row" do
    test "service_opts_fields/0 excludes raw secret keys" do
      keys = Keyword.keys(S3.service_opts_fields())

      refute :access_key_id in keys
      refute :secret_access_key in keys

      # Non-secret connection shape is still persistable.
      assert :bucket in keys
      assert :region in keys
      assert :endpoint_url in keys
    end

    test "inline credentials are not persisted by a direct-upload preparation" do
      assert {:ok, %{url: url, blob: blob}} =
               Operations.prepare_direct_upload(ConfigurablePost, :avatar,
                 filename: "photo.jpg",
                 content_type: "image/jpeg",
                 byte_size: 123
               )

      # The inline credentials still work at runtime: the presign was produced.
      assert is_binary(url)

      # Exactly the connection shape is persisted: no credential keys, and what
      # asynchronous operations need to rebuild the service.
      assert {:ok, row} = Ash.get(Blob, blob.id)
      persisted = Map.new(row.service_opts || %{}, fn {key, value} -> {to_string(key), value} end)

      assert persisted == %{"bucket" => "test-bucket", "region" => "us-east-1"}
    end
  end
end
