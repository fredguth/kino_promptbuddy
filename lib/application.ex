defmodule KinoPromptBuddy.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {:module, Kino.PromptBuddy} = Code.ensure_compiled(Kino.PromptBuddy)
    Kino.SmartCell.register(Kino.PromptBuddy)
    children = []
    opts = [strategy: :one_for_one, name: KinoPromptBuddy.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
