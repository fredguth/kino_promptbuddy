defmodule Kino.PromptBuddy.CellInserter do
  alias Livebook.Session
  alias Kino.PromptBuddy.Context

  def insert_before(session_ctx_or_id, current_cell_id, type \\ :markdown, source \\ "")

  def insert_before({:ok, node, session}, current_cell_id, type, source) do
    with {:ok, notebook} <- {:ok, :erpc.call(node, Session, :get_notebook, [session.pid])},
         {:ok, section, index} <- fetch_section_and_index(notebook, current_cell_id) do
      :erpc.call(node, Session, :insert_cell, [
        session.pid,
        section.id,
        index,
        type,
        %{source: source}
      ])
    end
  end

  def insert_before(session_id, current_cell_id, type, source) when is_binary(session_id) do
    case Context.fetch_session(session_id) do
      {:ok, _node, _session} = session_ctx ->
        insert_before(session_ctx, current_cell_id, type, source)

      error ->
        error
    end
  end

  def insert_before(_, _, _, _), do: {:error, :invalid_session}

  defp fetch_section_and_index(%{sections: sections}, cell_id) do
    sections
    |> Enum.reduce_while({:error, :cell_not_found}, fn section, _ ->
      case Enum.find_index(section.cells, &(&1.id == cell_id)) do
        nil -> {:cont, {:error, :cell_not_found}}
        idx -> {:halt, {:ok, section, idx}}
      end
    end)
  end
end
