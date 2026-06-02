defmodule AshStorage.AttachmentDefinitionTest do
  use ExUnit.Case, async: true

  alias AshStorage.AttachmentDefinition

  test "storage_key/3 generates a non-empty key" do
    definition = %AttachmentDefinition{name: :file, type: :one}

    assert {:ok, key} = AttachmentDefinition.storage_key(definition, nil, nil)
    assert is_binary(key) and key != ""
  end
end
