defmodule AshStorage.BlobResource.Calculations.ParsedServiceOpts do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context) do
    [:service_name, :service_opts]
  end

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      service_mod = record.service_name
      stored_opts = record.service_opts || %{}

      if Code.ensure_loaded?(service_mod) and function_exported?(service_mod, :service_opts_fields, 0) do
        fields = service_mod.service_opts_fields()

        case Ash.Type.cast_stored(Ash.Type.Keyword, stored_opts, fields: fields) do
          {:ok, opts} -> opts
          _ -> []
        end
      else
        []
      end
    end)
  end
end
