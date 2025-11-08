defmodule Kino.PromptBuddy do
  @moduledoc false

  use Kino.JS, assets_path: "assets/kino_promptbuddy"
  use Kino.JS.Live
  use Kino.SmartCell, name: "Prompt Buddy"

  alias Kino.PromptBuddy.Context

  # -- Public API --------------------------------------------------------------

  def new(), do: Kino.JS.Live.new(__MODULE__, %{})
  def history_to_messages(history) do
    Enum.flat_map(history, fn
      {u, a} -> [ReqLLM.Context.user(u), ReqLLM.Context.assistant(a)]
      # Extend here if you later store tool/system messages
    end)
  end
  def get_history(cell_id) do
    :persistent_term.get(history_key(cell_id), [])
  end

  def put_history(cell_id, history) do
    :persistent_term.put(history_key(cell_id), history)
  end


  # -- Per-cell chat history ---------------------------------------------------

  defp history_key(cell_id), do: {:promptbuddy, cell_id}



  # -- Live callbacks ----------------------------------------------------------

  @impl true
  def init(attrs, ctx) do
    ReqLLM.put_key(:openrouter_api_key, System.get_env("LB_OPENROUTER_API_KEY"))
    source = attrs["source"] || ""

    # Get the cell_id - use the one from attrs if available (for persistence),
    # otherwise generate it now using Context.get_current_cell_id()
    cell_id = attrs["cell_id"] || Context.get_current_cell_id()

    # Register this Smart Cell process so generated code can find it
    # Unregister first in case we're reinitializing
    try do
      Process.unregister(smart_cell_name(cell_id))
    rescue
      ArgumentError -> :ok
    end

    Process.register(self(), smart_cell_name(cell_id))
    IO.puts("[PromptBuddy] Registered as #{inspect(smart_cell_name(cell_id))}")

    {:ok,
     assign(ctx,
       source: source,
       session_id: attrs["session_id"],
       model: attrs["model"] || "openrouter:anthropic/claude-sonnet-4.5",
       n_every: attrs["n_every"] || 24,
       cell_id: cell_id
     ),
     editor: [source: source, language: "markdown", placement: :top]}
  end

  defp smart_cell_name(cell_id), do: :"promptbuddy_#{cell_id}"

  @impl true
  def handle_connect(ctx) do
    IO.puts("[PromptBuddy] handle_connect: cell_id=#{inspect(ctx.assigns[:cell_id])}")

    {:ok,
     %{
       session_id: ctx.assigns[:session_id],
       model: ctx.assigns[:model],
       n_every: ctx.assigns[:n_every],
       cell_id: ctx.assigns[:cell_id]
     }, ctx}
  end

  @impl true
  def handle_editor_change(source, ctx), do: {:ok, assign(ctx, source: source)}

  @impl true
  def handle_event("set_session_id", session_url, ctx) do
    session_id =
      case Regex.run(~r{/sessions/([^/]+)/}, session_url) do
        [_, id] -> id
        _ -> nil
      end

    {:noreply, assign(ctx, session_id: session_id)}
  end

  @impl true
  def handle_event("set_cell_id", new_id, ctx) do
    old_id = ctx.assigns[:cell_id]

    cond do
      is_nil(new_id) or new_id == "" ->
        {:noreply, ctx}

      new_id == old_id ->
        {:noreply, ctx}

      true ->
        migrate_history(old_id, new_id)
        reregister_process(old_id, new_id)
        {:noreply, assign(ctx, cell_id: new_id)}
    end
  end

  @impl true
  def handle_event("update_model", model_key, ctx) do
    model =
      case model_key do
        "sonnet" -> "openrouter:anthropic/claude-sonnet-4.5"
        "haiku"  -> "openrouter:anthropic/claude-haiku-4.5"
        "opus"   -> "openrouter:anthropic/claude-opus-4.1"
        _        -> "openrouter:anthropic/claude-sonnet-4.5"
      end

    {:noreply, assign(ctx, model: model)}
  end

  @impl true
  def handle_event("clear_source", _payload, ctx) do
    ctx =
      ctx
      |> assign(source: "")
      |> Kino.JS.Live.Context.reconfigure_smart_cell(editor: [source: ""])

    Kino.JS.Live.Context.broadcast_event(ctx, "focus_editor", %{})

    {:noreply, ctx}
  end



  @impl true
  def handle_info({:clear_editor, cell_id}, ctx) do
    IO.puts("[PromptBuddy] Received :clear_editor message for cell_id: #{inspect(cell_id)}")

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

  defp migrate_history(nil, _new_id), do: :ok
  defp migrate_history(_old_id, nil), do: :ok
  defp migrate_history(old_id, new_id) when old_id == new_id, do: :ok
  defp migrate_history(old_id, new_id) do
    history = get_history(old_id)
    put_history(new_id, history)
  end

  defp reregister_process(nil, new_id) do
    Process.register(self(), smart_cell_name(new_id))
  end

  defp reregister_process(old_id, new_id) when old_id == new_id, do: :ok
  defp reregister_process(old_id, new_id) do
    try do
      Process.unregister(smart_cell_name(old_id))
    rescue
      ArgumentError -> :ok
    end

    Process.register(self(), smart_cell_name(new_id))
  end





  # -- Helper functions for to_source ------------------------------------------

  def stream_response_and_update_history(model, messages, body, outer, user_text, chat_history, current_cell_id, n_every) do
    case ReqLLM.stream_text(model, messages) do
      {:ok, response} ->
        final_text = handle_streaming_response(response, body, n_every)
        new_history = [{user_text, final_text} | chat_history]
        update_chat_history(current_cell_id, new_history)
        render_final_chat_history(outer, new_history)

      {:error, err} ->
        Kino.Frame.render(body, Kino.Markdown.new("**Error**: #{inspect(err)}"))
    end
  end

  def handle_streaming_response(response, body, n_every) do
    {final_text, _count} =
      response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce({"", 0}, fn token, {acc, n} ->
        new_text = acc <> token
        if rem(n + 1, n_every) == 0 do
          Kino.Frame.render(body, Kino.Markdown.new(new_text))
        end
        {new_text, n + 1}
      end)

    final_text
  end

  def update_chat_history(current_cell_id, new_history) do
    (fn -> Kino.PromptBuddy |> :erlang.apply(:put_history, [current_cell_id, new_history]) end).()
  end

  def render_final_chat_history(outer, new_history) do
    all_msgs =
      new_history
      |> Enum.flat_map(fn {u, a} ->
        [
          Kino.Markdown.new("**Buddy**:"),
          Kino.Markdown.new("#{a}"),
          Kino.Markdown.new("---"),
          Kino.Markdown.new("**You**:"),
          Kino.Markdown.new("#{u}"),
          Kino.Markdown.new("---"),
        ]
      end)

    Kino.Frame.render(outer, Kino.Layout.grid(all_msgs))
  end


  # -------------------------------------------------------------

  @impl true
  def to_source(attrs) do
    cell_id = attrs["cell_id"]

    quote do
      # ---------- PromptBuddy UI (auto-generated by SmartCell) ----------
      alias Kino.PromptBuddy.Context

      model           = unquote(attrs["model"])
      n_every         = unquote(attrs["n_every"])
      session_id      = unquote(attrs["session_id"])
      current_cell_id = Context.get_current_cell_id()
      user_text       = unquote(attrs["source"])
      smart_cell_pid  = Process.whereis(:"promptbuddy_#{unquote(cell_id)}")

      import Kino.Shorts
      outer = frame()
      body  = frame()

      chat_history =
        (fn -> Kino.PromptBuddy |> :erlang.apply(:get_history, [current_cell_id]) end).()

      # Show all previous messages plus current prompt
      previous_msgs =
        chat_history
        |> Enum.flat_map(fn {u, a} ->
          [
            Kino.Markdown.new("**Buddy**: #{a}"),
            Kino.Markdown.new("---"),
            Kino.Markdown.new("**You**: #{u}")
          ]
        end)

      current_prompt = Kino.Markdown.new("**You**: #{user_text}")
      buddy_header = Kino.Markdown.new("**Buddy**:")

      # Render all previous messages plus current prompt and streaming area
      Kino.Frame.render(
        outer,
        Kino.Layout.grid(previous_msgs ++ [current_prompt, buddy_header, body])
      )

      # Clear the editor after a small delay to ensure DOM is ready
      Task.start(fn ->
        Process.sleep(100)
        IO.puts("[PromptBuddy] smart_cell_pid = #{inspect(smart_cell_pid)}")
        IO.puts("[PromptBuddy] current_cell_id = #{inspect(current_cell_id)}")
        if smart_cell_pid do
          IO.puts("[PromptBuddy] Sending :clear_editor to #{inspect(smart_cell_pid)}")
          send(smart_cell_pid, {:clear_editor, current_cell_id})
        else
          IO.puts("[PromptBuddy] No smart_cell_pid found")
        end
      end)

      system_msg =
        ReqLLM.Context.system("""
        You are a patient pair-programming partner using **Polya's method** / **Socratic** style.
        PRIORITY: (1) Answer only the final PROMPT, (2) be brief, (3) one code fence if needed.
        """)

      prompt_msg =
        ReqLLM.Context.user("""
        --- BEGIN PROMPT ---
        #{user_text}
        --- END PROMPT ---
        """)

      precedent_msgs =
        case Context.get_notebook(session_id) do
          {:ok, nb} ->
            Context.build_precedent_messages(nb, current_cell_id)
          _ ->
            []
        end

      history_msgs =
        (fn -> Kino.PromptBuddy |> :erlang.apply(:history_to_messages, [chat_history]) end).()

      messages = [system_msg] ++ precedent_msgs ++ history_msgs ++ [prompt_msg]

      Task.start(fn ->
        (fn ->
          Kino.PromptBuddy
          |> :erlang.apply(:stream_response_and_update_history,
                          [model, messages, body, outer, user_text, chat_history, current_cell_id, n_every])
        end).()
      end)

      outer
      # ---------- /PromptBuddy UI ----------
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
      "cell_id" => ctx.assigns[:cell_id]
    }
  end
end
