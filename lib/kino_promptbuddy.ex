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

    # Register this Smart Cell process so generated code can find it
    # Unregister first in case we're reinitializing
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
       cell_id: cell_id
     ), editor: [source: source, language: "markdown", placement: :top]}
  end

  defp smart_cell_name(cell_id), do: :"promptbuddy_#{cell_id}"

  @impl true
  def handle_connect(ctx) do
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
    # front end is the place where we ca find the session id (in the url)
    session_id =
      case Regex.run(~r{/sessions/([^/]+)/}, session_url) do
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
        body,
        _outer,
        user_text,
        chat_history,
        current_cell_id,
        n_every,
        session_id,
        session_ctx \\ nil
      ) do
    case ReqLLM.stream_text(model, messages) do
      {:ok, response} ->
        final_text = handle_streaming_response(response, body, n_every)
        new_history = [{user_text, final_text} | chat_history]
        update_chat_history(current_cell_id, new_history)
        maybe_insert_response_cell(session_id, session_ctx, current_cell_id, final_text)

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
    put_history(current_cell_id, new_history)
  end

  def insert_user_cell(session_id, current_cell_id, user_text, session_ctx \\ nil) do
    maybe_insert_user_cell(session_id, session_ctx, current_cell_id, user_text)
  end

  defp maybe_insert_user_cell(nil, _session_ctx, _cell_id, _text), do: :ok
  defp maybe_insert_user_cell(_session_id, _session_ctx, _cell_id, text) when text in [nil, ""], do: :ok

  defp maybe_insert_user_cell(session_id, session_ctx, current_cell_id, user_text) do
    trimmed = String.trim(user_text)

    if trimmed == "" do
      :ok
    else
      session_ctx = ensure_session_ctx(session_ctx, session_id)

      case session_ctx do
        {:ok, _node, _session} ->
          CellInserter.insert_before(
            session_ctx,
            current_cell_id,
            :markdown,
            format_user_markdown(user_text)
          )

        _ ->
          :ok
      end
    end
  end

  defp maybe_insert_response_cell(nil, _session_ctx, _cell_id, _text), do: :ok

  defp maybe_insert_response_cell(_session_id, _session_ctx, _cell_id, text) when text in [nil, ""], do: :ok

  defp maybe_insert_response_cell(session_id, session_ctx, current_cell_id, final_text) do
    session_ctx = ensure_session_ctx(session_ctx, session_id)

    case session_ctx do
      {:ok, _node, _session} ->
        CellInserter.insert_before(
          session_ctx,
          current_cell_id,
          :markdown,
          format_buddy_markdown(final_text)
        )

      _ ->
        :ok
    end
  end

  defp format_user_markdown(text),
    do: "**User:**\n\n#{text || ""}"

  defp format_buddy_markdown(text),
    do: "**Buddy:**\n\n#{text || ""}"

  defp ensure_session_ctx({:ok, _node, _session} = ctx, _session_id), do: ctx

  defp ensure_session_ctx(_ctx, session_id) when is_binary(session_id),
    do: Context.fetch_session(session_id)

  defp ensure_session_ctx(_ctx, _), do: {:error, :invalid_session}

  # -------------------------------------------------------------

  @impl true
  def to_source(attrs) do
    cell_id = attrs["cell_id"]

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
          nil ->
            nil

          _ ->
            case Context.fetch_session(session_id) do
              {:ok, _node, _session} = ctx -> ctx
              _ -> nil
            end
        end

      import Kino.Shorts
      outer = frame()
      body = frame()

      chat_history = Kino.PromptBuddy.get_history(current_cell_id)
      prompt_blank? = String.trim(user_text) == ""

      # Render only the streaming area; historical conversation lives in inserted cells
      Kino.Frame.render(outer, Kino.Layout.grid([body]))

      unless prompt_blank? do
        # Clear the editor after render and a small delay
        Task.start(fn ->
          Process.sleep(100)

          if smart_cell_pid,
            do: send(smart_cell_pid, {:clear_editor, current_cell_id})
        end)

        Kino.PromptBuddy.insert_user_cell(session_id, current_cell_id, user_text, session_ctx)

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
          case Context.get_notebook_from_session(session_ctx) do
            {:ok, nb} -> Context.build_precedent_messages(nb, current_cell_id)
            _ -> []
          end

        history_msgs = Kino.PromptBuddy.history_to_messages(chat_history)

        messages = [system_msg] ++ precedent_msgs ++ history_msgs ++ [prompt_msg]

        Task.start(fn ->
          Kino.PromptBuddy.stream_response_and_update_history(
            model,
            messages,
            body,
            outer,
            user_text,
            chat_history,
            current_cell_id,
            n_every,
            session_id,
            session_ctx
          )
        end)
      end

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
