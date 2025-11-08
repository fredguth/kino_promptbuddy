defmodule KinoPromptBuddy.MixProject do
  use Mix.Project

  @version "0.0.1"
  @github "https://github.com/fredguth/kino_promptbuddy"

  def project do
    [
      app: :kino_promptbuddy,
      version: @version,
      elixir: "~> 1.18",
      description: "PromptBuddy is a Livebook Smart Cell that allows pair programming with LLMs.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "KinoPromptBuddy",
      source_url: @github,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {KinoPromptBuddy.Application, []}
    ]
  end

  defp deps do
    [
    {:kino, "~> 0.17.0"},
     {:req_llm, "~> 1.0"}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @github,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @github
      }
    ]
  end
end
