defmodule AshStorage.BlobIOTest do
  use ExUnit.Case, async: false

  alias AshStorage.BlobIO
  alias AshStorage.Info
  alias AshStorage.Service
  alias AshStorage.Test.Post

  setup do
    Service.Test.reset!()
    :ok
  end

  test "context projects to service context" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        actor: :actor,
        tenant: "tenant",
        operation: :attach
      )

    service_ctx = BlobIO.BlobContext.to_service_context(bctx, table: :custom)

    assert %Service.Context{} = service_ctx
    assert service_ctx.service_opts == [table: :custom]
    assert service_ctx.resource == Post
    assert service_ctx.attachment == attachment
    assert service_ctx.actor == :actor
    assert service_ctx.tenant == "tenant"
  end

  test "write creates a blob and read returns stored bytes" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("hello world", bctx,
               filename: "hello.txt",
               content_type: "text/plain",
               metadata: %{"source" => "test"}
             )

    assert blob.filename == "hello.txt"
    assert blob.content_type == "text/plain"
    assert blob.byte_size == 11
    assert blob.checksum == Base.encode64(:crypto.hash(:md5, "hello world"))
    assert blob.metadata == %{"source" => "test"}
    assert Service.Test.exists?(blob.key)

    read_bctx = BlobIO.BlobContext.new(blob: blob, operation: :download)

    assert {:ok, "hello world"} = BlobIO.read(blob, read_bctx)
  end

  test "serving_strategy returns the service URL strategy" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    assert {:service_url, "http://test.local/storage/" <> _} =
             BlobIO.serving_strategy(blob, serve_bctx)

    assert BlobIO.url(blob, serve_bctx) == "http://test.local/storage/#{blob.key}"
  end

  test "serving derives the service from the blob's persisted opts, not the runtime config" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    # Persist a blob whose stored service_opts pin a base_url that the runtime
    # DSL service config does not set.
    write_bctx =
      BlobIO.BlobContext.new(resource: Post, attachment: attachment, operation: :attach)

    {:ok, blob} =
      BlobIO.write("data", write_bctx,
        filename: "photo.jpg",
        service: {Service.Test, [base_url: "http://persisted.example/store"]}
      )

    blob = Ash.load!(blob, :parsed_service_opts)
    assert Keyword.get(blob.parsed_service_opts, :base_url) == "http://persisted.example/store"

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    # Serving must use the blob's persisted service_opts so it resolves the same
    # location as reading. Previously serving used the runtime service config
    # (no base_url) and diverged from the read path.
    assert BlobIO.url(blob, serve_bctx) == "http://persisted.example/store/#{blob.key}"
  end

  test "serving_strategy can return a proxy URL strategy" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    opts = [serve: :proxy, proxy_base_url: "/proxy/storage/"]
    expected_url = "/proxy/storage/#{blob.key}"

    assert {:proxy_url, ^expected_url} = BlobIO.serving_strategy(blob, serve_bctx, opts)

    assert BlobIO.url(blob, serve_bctx, opts) == expected_url
  end

  test "proxy URL strategy can sign proxy URLs" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    url =
      BlobIO.url(blob, serve_bctx,
        serve: :proxy,
        proxy_base_url: "/proxy/storage",
        proxy_secret: "proxy-secret",
        expires_in: 300,
        disposition: "attachment",
        filename: "photo.jpg"
      )

    assert %URI{path: "/proxy/storage/" <> key, query: query} = URI.parse(url)
    assert key == blob.key

    params = URI.decode_query(query)
    expires_at = String.to_integer(params["expires"])

    assert params["token"] == AshStorage.Token.sign("proxy-secret", blob.key, expires_at)
    assert params["disposition"] == "attachment"
    assert params["filename"] == "photo.jpg"
  end

  test "proxy URL strategy can sign proxy URLs from access declaration" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    url =
      BlobIO.url(blob, serve_bctx,
        serve: :proxy,
        proxy_base_url: "/proxy/storage",
        access: {:signed, secret: "proxy-secret"},
        expires_in: 300
      )

    assert %URI{path: "/proxy/storage/" <> key, query: query} = URI.parse(url)
    assert key == blob.key

    params = URI.decode_query(query)
    expires_at = String.to_integer(params["expires"])

    assert params["token"] == AshStorage.Token.sign("proxy-secret", blob.key, expires_at)
  end

  test "prepare_direct_upload creates a pending blob and upload info" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :direct_upload
      )

    assert {:ok, result} =
             BlobIO.prepare_direct_upload(bctx,
               filename: "photo.jpg",
               content_type: "image/jpeg",
               byte_size: 123
             )

    assert result.blob.filename == "photo.jpg"
    assert result.blob.content_type == "image/jpeg"
    assert result.blob.byte_size == 123
    assert result.url == "http://test.local/storage/direct/#{result.blob.key}"
  end
end
