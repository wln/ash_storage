defmodule AshStorage.Encryption.ScrubbedError do
  @moduledoc false
  # Key-manager / vault exceptions can carry request context or partial
  # secret material in their message or captured arguments. When invocation of a
  # key manager or vault raises, we surface ONLY the exception module plus a
  # normalized code position (module/function/arity/file/line) from the top
  # stack frame. The message is never included, and any captured argument LIST
  # is reduced to its length so argument values never leak.

  @type t :: %{
          module: module(),
          at:
            %{
              module: module(),
              function: atom(),
              arity: non_neg_integer(),
              file: String.t() | nil,
              line: non_neg_integer() | nil
            }
            | nil
        }

  @doc """
  Reduce an exception + stacktrace to a non-sensitive, position-only descriptor.

  Non-exception terms are returned unchanged (callers may already pass a safe value).
  """
  def scrub(exception, stacktrace) when is_exception(exception) do
    %{module: exception.__struct__, at: location(stacktrace)}
  end

  def scrub(other, _stacktrace), do: other

  defp location([{module, function, arity_or_args, loc} | _]) do
    %{
      module: module,
      function: function,
      arity: if(is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args),
      file: loc |> Keyword.get(:file) |> normalize_file(),
      line: Keyword.get(loc, :line)
    }
  end

  defp location(_stacktrace), do: nil

  defp normalize_file(nil), do: nil
  defp normalize_file(file), do: to_string(file)
end
