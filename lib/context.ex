defmodule Kino.PromptBuddy.Context do
  @moduledoc false

  # -- Impure helpers (Livebook/ERPC boundary) --------------------------------

  def get_session_id(kino), do: Kino.JS.Live.call(kino, :get_session_id)

  def get_current_cell_id() do
    Kino.Bridge.get_evaluation_file()
    |> String.split("#cell:")
    |> List.last()
  end

  def get_notebook(session_id) do
    with {:ok, node_norm, session} <- fetch_session(session_id) do
      {:ok, :erpc.call(node_norm, Livebook.Session, :get_notebook, [session.pid])}
    end
  end

  def get_notebook_from_session({:ok, node_norm, session}) do
    {:ok, :erpc.call(node_norm, Livebook.Session, :get_notebook, [session.pid])}
  end

  def get_notebook_from_session(_), do: {:error, :invalid_session}


  def fetch_session(session_id) when is_binary(session_id) do
    node_norm = normalized_node()
    Node.set_cookie(node_norm, Node.get_cookie())
    sessions = :erpc.call(node_norm, Livebook.Tracker, :list_sessions, [])

    case Enum.find(sessions, &(&1.id == session_id)) do
      nil -> {:error, :session_not_found}
      session -> {:ok, node_norm, session}
    end
  end

  def fetch_session(_), do: {:error, :invalid_session_id}

  def normalized_node do
    node()
    |> Atom.to_string()
    |> String.replace(~r/--[^@]+@/, "@")
    |> String.to_atom()
  end

  # -- Pure transforms ---------------------------------------------------------

  @cell_code     :"Elixir.Livebook.Notebook.Cell.Code"
  @cell_markdown :"Elixir.Livebook.Notebook.Cell.Markdown"
  @cell_smart    :"Elixir.Livebook.Notebook.Cell.Smart"

  def build_precedent_messages(nb) when is_map(nb) do
    current_cell_id = get_current_cell_id()              # <- fixed
    build_precedent_messages(nb, current_cell_id)
  end

  def build_precedent_messages(nb, current_cell_id) when is_map(nb) do
    nb
    |> all_cells()
    |> Enum.take_while(&(&1.id != current_cell_id))
    |> Enum.flat_map(&cell_to_messages/1)
  end

  defp all_cells(%{sections: secs}),
    do: Enum.flat_map(secs, & &1.cells)

  def cell_to_messages(%{__struct__: @cell_code, source: src, outputs: outs}) do
    source_msg(src) ++ output_msgs(outs)
  end

  def cell_to_messages(%{__struct__: @cell_markdown, source: md}) do
    # Parse markdown to detect if it's a Buddy response or user message
    md = String.trim(md)

    cond do
      # Buddy response - starts with **Buddy:**
      String.starts_with?(md, "**Buddy:**") ->
        content = md |> String.replace_prefix("**Buddy:**", "") |> String.trim()
        if content == "", do: [], else: [ReqLLM.Context.assistant(content)]

      # User message - starts with **User:**
      String.starts_with?(md, "**User:**") ->
        content = md |> String.replace_prefix("**User:**", "") |> String.trim()
        if content == "", do: [], else: [ReqLLM.Context.user(content)]

      # Plain markdown (shouldn't happen with new code, but handle gracefully)
      md != "" ->
        [ReqLLM.Context.user(md)]

      # Empty
      true ->
        []
    end
  end

  def cell_to_messages(%{__struct__: @cell_smart, outputs: outs}),
    do: output_msgs(outs)

  def cell_to_messages(_), do: []

  def source_msg(src) when is_binary(src) do
    src = String.trim(src)
    if src == "", do: [], else: [ReqLLM.Context.user(src)]
  end

  def output_msgs(outs) when is_list(outs) do
    outs
    |> Enum.flat_map(fn
      # common Livebook text outputs
      {_id, %{type: :plain_text,    text: text}} -> [ReqLLM.Context.assistant(clean_text(text))]
      {_id, %{type: :terminal_text, text: text}} -> [ReqLLM.Context.assistant(clean_text(text))]

      # generic text fallback (covers some Kinos)
      {_id, %{text: text}}                       -> [ReqLLM.Context.assistant(clean_text(text))]

      # nested outputs
      {_id, %{outputs: nested}}                  -> output_msgs(nested)

      _ -> []
    end)
  end

  def clean_text(text),
    do: text |> String.replace(~r/\e\[[\d;]*m/, "") |> String.trim()
end
