defmodule Kino.PromptBuddy do
  @moduledoc false

  use Kino.JS, assets_path: "assets/kino_promptbuddy"
  use Kino.JS.Live
  use Kino.SmartCell, name: "Prompt Buddy"

  alias Kino.PromptBuddy.{Context, CellInserter}

  # -- Public API --------------------------------------------------------------

  def new(), do: Kino.JS.Live.new(__MODULE__, %{})

  def history_to_messages(history) do
    Enum.flat_map(history, fn
      {u, a} -> [ReqLLM.Context.user(u), ReqLLM.Context.assistant(a)]
    end)
  end

  def get_history(cell_id) do
    :persistent_term.get(history_key(cell_id), [])
  end

  def put_history(cell_id, history) do
    :persistent_term.put(history_key(cell_id), history)
  end

  def history_key(cell_id), do: {:promptbuddy, cell_id}

  # -- Live callbacks ----------------------------------------------------------

  @impl true
  def init(attrs, ctx) do
    ReqLLM.put_key(:openrouter_api_key, System.get_env("LB_OPENROUTER_API_KEY"))
    source = attrs["source"] || ""
    cell_id = attrs["cell_id"] || Context.get_current_cell_id()
    active_tab = attrs["active_tab"] || "prompt"

    # Register this Smart Cell process so generated code can find it
    try do
      Process.unregister(smart_cell_name(cell_id))
    rescue
      ArgumentError -> :ok
    end
    Process.register(self(), smart_cell_name(cell_id))

    {:ok,
     assign(ctx,
       source: source,
       session_id: attrs["session_id"],
       model: attrs["model"] || "openrouter:anthropic/claude-sonnet-4.5",
       n_every: attrs["n_every"] || 24,
       cell_id: cell_id,
       active_tab: active_tab
     ), editor: [source: source, placement: :top, language: "markdown"]}
  end

  defp smart_cell_name(cell_id), do: :"promptbuddy_#{cell_id}"

  @impl true
  def handle_connect(ctx) do
    {:ok,
     %{
       session_id: ctx.assigns[:session_id],
       model: ctx.assigns[:model],
       n_every: ctx.assigns[:n_every],
       cell_id: ctx.assigns[:cell_id],
       active_tab: ctx.assigns[:active_tab] || "prompt"
     }, ctx}
  end

  @impl true
  def handle_editor_change(source, ctx), do: {:ok, assign(ctx, source: source)}

  @impl true
  def handle_event("set_session_id", session_url, ctx) do
    session_id = case Regex.run(~r{/sessions/([^/]+)/}, session_url) do
      [_, id] -> id
      _ -> nil
    end
    {:noreply, assign(ctx, session_id: session_id)}
  end

  @impl true
  def handle_event("update_model", model_key, ctx) do
    model =
      case model_key do
        "sonnet" -> "openrouter:anthropic/claude-sonnet-4.5"
        "haiku" -> "openrouter:anthropic/claude-haiku-4.5"
        "opus" -> "openrouter:anthropic/claude-opus-4.1"
        _ -> "openrouter:anthropic/claude-sonnet-4.5"
      end

    {:noreply, assign(ctx, model: model)}
  end

  @impl true
  def handle_event("tab_changed", %{"tab" => tab}, ctx) do
    {:noreply, assign(ctx, active_tab: tab)}
  end

  @impl true
  def handle_info({:clear_editor, cell_id}, ctx) do
    ctx =
      ctx
      |> assign(source: "")
      |> Kino.JS.Live.Context.reconfigure_smart_cell(editor: [source: ""])

    Kino.JS.Live.Context.broadcast_event(ctx, "focus_editor", %{cell_id: cell_id})

    {:noreply, ctx}
  end

  @impl true
  def handle_call(:get_session_id, _from, ctx),
    do: {:reply, ctx.assigns[:session_id], ctx}


  # -- Helper functions for to_source ------------------------------------------

  def stream_response_and_update_history(
        model,
        messages,
        current_cell_id,
        user_text,
        chat_history,
        n_every,
        session_id,
        session_ctx \\ nil
      ) do
    session_ctx = ensure_session_ctx(session_ctx, session_id)

    case ReqLLM.stream_text(model, messages) do
      {:ok, response} ->
        final_text = handle_streaming_response(response, session_ctx, current_cell_id, n_every)
        new_history = [{user_text, final_text} | chat_history]
        update_chat_history(current_cell_id, new_history)

      {:error, err} ->
        maybe_insert_error_cell(session_id, session_ctx, current_cell_id, err)
    end
  end

  def handle_streaming_response(response, session_ctx, current_cell_id, n_every) do
    # Insert a markdown cell for the assistant response
    {:ok, response_cell_id} = insert_response_cell(session_ctx, current_cell_id)

    # Wait a moment for the cell to be registered in session data
    Process.sleep(50)

    # Stream content into the cell with lazy evaluation using Text.Delta
    final_text =
      response
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.transform({"", 0}, fn token, {acc, n} ->
        new_text = acc <> token

        if rem(n + 1, n_every) == 0 do
          update_cell_content(session_ctx, response_cell_id, new_text)
        end

        {[new_text], {new_text, n + 1}}
      end)
      |> Enum.to_list()
      |> List.last()

    # Final update to ensure we have all the text
    update_cell_content(session_ctx, response_cell_id, final_text)
    final_text
  end

  defp insert_response_cell({:ok, _node, _session} = session_ctx, current_cell_id) do
    # Insert a markdown cell for the assistant response
    initial_content = format_buddy_markdown("")

    CellInserter.insert_before(
      session_ctx,
      current_cell_id,
      :markdown,
      initial_content
    )
  end

  defp insert_response_cell(_session_ctx, _current_cell_id) do
    {:error, :no_session}
  end

  defp update_cell_content({:ok, node, session}, cell_id, text) do
    formatted_text = format_buddy_markdown(text)

    # Get the current cell info to get revision and current source length
    data = :erpc.call(node, Livebook.Session, :get_data, [session.pid])

    case data.cell_infos[cell_id] do
      nil ->
        # Cell not yet in session data, skip update
        :ok

      cell_info ->
        source_info = cell_info.sources[:primary]

        # Get current source by fetching the cell from the notebook
        notebook = :erpc.call(node, Livebook.Session, :get_notebook, [session.pid])
        current_cell =
          notebook.sections
          |> Enum.flat_map(& &1.cells)
          |> Enum.find(&(&1.id == cell_id))

        current_source = if current_cell, do: current_cell.source, else: ""
        current_length = String.length(current_source)
        revision = source_info.revision

        # Create a delta that deletes old content and inserts new content
        delta =
          :erpc.call(node, Livebook.Text.Delta, :new, [])
          |> then(fn d -> :erpc.call(node, Livebook.Text.Delta, :delete, [d, current_length]) end)
          |> then(fn d -> :erpc.call(node, Livebook.Text.Delta, :insert, [d, formatted_text]) end)

        # Create selection
        selection = :erpc.call(node, Livebook.Text.Selection, :new, [[{0, 0}]])

        # Apply the delta to update the cell content
        :erpc.call(node, Livebook.Session, :apply_cell_delta, [
          session.pid,
          cell_id,
          :primary,
          delta,
          selection,
          revision
        ])
    end
  end

  defp update_cell_content(_, _cell_id, _text), do: :ok

  defp maybe_insert_error_cell(_session_id, {:ok, node, session}, current_cell_id, err) do
    CellInserter.insert_before(
      {:ok, node, session},
      current_cell_id,
      :markdown,
      "**Error**: #{inspect(err)}"
    )
  end
  defp maybe_insert_error_cell(_, _, _, _), do: :ok

  def update_chat_history(current_cell_id, new_history) do
    put_history(current_cell_id, new_history)
  end

  def insert_user_cell(session_id, current_cell_id, user_text, session_ctx \\ nil) do
    if session_id && user_text && String.trim(user_text) != "" do
      session_ctx = ensure_session_ctx(session_ctx, session_id)
      case session_ctx do
        {:ok, _node, _session} ->
          CellInserter.insert_before(
            session_ctx,
            current_cell_id,
            :markdown,
            format_user_markdown(user_text)
          )
        _ -> :ok
      end
    else
      :ok
    end
  end



  defp format_user_markdown(text), do: "**User:**\n\n#{text || ""}"
  defp format_buddy_markdown(text), do: "**Buddy:**\n\n#{text || ""}"

  defp ensure_session_ctx({:ok, _node, _session} = ctx, _session_id), do: ctx

  defp ensure_session_ctx(_ctx, session_id) when is_binary(session_id),
    do: Context.fetch_session(session_id)

  defp ensure_session_ctx(_ctx, _), do: {:error, :invalid_session}

  # -------------------------------------------------------------

  @impl true
  def to_source(attrs) do
    cell_id = attrs["cell_id"]
    active_tab = attrs["active_tab"] || "prompt"

    case active_tab do
      "prompt" -> to_source_prompt(attrs, cell_id)
      "note" -> to_source_note(attrs, cell_id)
      "code" -> to_source_code(attrs, cell_id)
      _ -> to_source_prompt(attrs, cell_id)
    end
  end

  defp to_source_prompt(attrs, cell_id) do
    quote do
      # ---------- PromptBuddy UI (auto-generated by SmartCell) ----------
      alias Kino.PromptBuddy.Context

      model = unquote(attrs["model"])
      n_every = unquote(attrs["n_every"])
      session_id = unquote(attrs["session_id"])
      current_cell_id = Context.get_current_cell_id()
      user_text = unquote(attrs["source"])
      smart_cell_pid = Process.whereis(:"promptbuddy_#{unquote(cell_id)}")

      session_ctx =
        case session_id do
          nil -> nil
          _ ->
            case Context.fetch_session(session_id) do
              {:ok, _node, _session} = ctx -> ctx
              _ -> nil
            end
        end

      chat_history = Kino.PromptBuddy.get_history(current_cell_id)

      unless String.trim(user_text) == "" do
        Task.start(fn ->
          Process.sleep(100)
          if smart_cell_pid, do: send(smart_cell_pid, {:clear_editor, current_cell_id})
        end)

        Kino.PromptBuddy.insert_user_cell(session_id, current_cell_id, user_text, session_ctx)

        system_msg =
          ReqLLM.Context.system("""
          You are a patient pair-programming partner using **Polya's method** / **Socratic** style.
          PRIORITY: (1) Answer only the final PROMPT, (2) be brief, (3) one code fence if needed. (4) When writing markdown only use headings level 3 or 4 (levels 1 and 2 are reserved.)
          """)

        prompt_msg =
          ReqLLM.Context.user("""
          --- BEGIN PROMPT ---
          #{user_text}
          --- END PROMPT ---
          """)

        precedent_msgs =
          case Context.get_notebook_from_session(session_ctx) do
            {:ok, nb} -> Context.build_precedent_messages(nb, current_cell_id)
            _ -> []
          end

        history_msgs = Kino.PromptBuddy.history_to_messages(chat_history)

        messages = [system_msg] ++ precedent_msgs ++ history_msgs ++ [prompt_msg]

        Task.start(fn ->
          try do
            Kino.PromptBuddy.stream_response_and_update_history(
              model,
              messages,
              current_cell_id,
              user_text,
              chat_history,
              n_every,
              session_id,
              session_ctx
            )
          rescue
            e ->
              IO.inspect(e, label: "ERROR in stream_response_and_update_history")
              IO.inspect(__STACKTRACE__, label: "STACKTRACE")
              reraise e, __STACKTRACE__
          end
        end)
      end

      nil
      # ---------- /PromptBuddy UI ----------
    end
    |> Kino.SmartCell.quoted_to_string()
  end

  defp to_source_note(attrs, cell_id) do
    quote do
      # ---------- PromptBuddy Note (auto-generated by SmartCell) ----------
      alias Kino.PromptBuddy.Context

      session_id = unquote(attrs["session_id"])
      current_cell_id = Context.get_current_cell_id()
      note_text = unquote(attrs["source"])
      smart_cell_pid = Process.whereis(:"promptbuddy_#{unquote(cell_id)}")

      unless String.trim(note_text) == "" do
        # Clear the editor after render
        Task.start(fn ->
          Process.sleep(100)
          if smart_cell_pid, do: send(smart_cell_pid, {:clear_editor, current_cell_id})
        end)

        session_ctx =
          case session_id do
            nil -> nil
            _ -> case Context.fetch_session(session_id) do
              {:ok, _node, _session} = ctx -> ctx
              _ -> nil
            end
          end

        # Insert a markdown cell with the note content, prefixed with "User:"
        case session_ctx do
          {:ok, _node, _session} ->
            Kino.PromptBuddy.CellInserter.insert_before(
              session_ctx,
              current_cell_id,
              :markdown,
              "**User:**\n\n#{note_text}"
            )
          _ -> :ok
        end
      end

      nil
      # ---------- /PromptBuddy Note ----------
    end
    |> Kino.SmartCell.quoted_to_string()
  end

  defp to_source_code(attrs, cell_id) do
    quote do
      # ---------- PromptBuddy Code (auto-generated by SmartCell) ----------
      alias Kino.PromptBuddy.Context

      session_id = unquote(attrs["session_id"])
      current_cell_id = Context.get_current_cell_id()
      code_text = unquote(attrs["source"])
      smart_cell_pid = Process.whereis(:"promptbuddy_#{unquote(cell_id)}")

      unless String.trim(code_text) == "" do
        # Clear the editor after render
        Task.start(fn ->
          Process.sleep(100)
          if smart_cell_pid, do: send(smart_cell_pid, {:clear_editor, current_cell_id})
        end)

        session_ctx =
          case session_id do
            nil -> nil
            _ -> case Context.fetch_session(session_id) do
              {:ok, _node, _session} = ctx -> ctx
              _ -> nil
            end
          end

        # Insert a label markdown cell first, then the code cell
        case session_ctx do
          {:ok, _node, _session} ->
            Kino.PromptBuddy.CellInserter.insert_before(
              session_ctx,
              current_cell_id,
              :markdown,
              "**Code:**"
            )

            Kino.PromptBuddy.CellInserter.insert_before(
              session_ctx,
              current_cell_id,
              :code,
              code_text
            )
          _ -> :ok
        end
      end

      nil
      # ---------- /PromptBuddy Code ----------
    end
    |> Kino.SmartCell.quoted_to_string()
  end

  @impl true
  def to_attrs(ctx) do
    %{
      "source" => ctx.assigns[:source],
      "session_id" => ctx.assigns[:session_id],
      "model" => ctx.assigns[:model],
      "n_every" => ctx.assigns[:n_every],
      "cell_id" => ctx.assigns[:cell_id],
      "active_tab" => ctx.assigns[:active_tab] || "prompt"
    }
  end
end
