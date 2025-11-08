# Kino PromptBuddy

An Elixir Livebook smart cell for pair programming with LLMs, keeping a conversation about the notebook you are actively creating.

## Inspiration

This project was inspired by [Jeremy Howard's](https://en.wikipedia.org/wiki/Jeremy_Howard_(entrepreneur)) [Solve.it](https://solve.it.com), an app and methodology designed to augment human capabilities with AI. PromptBuddy brings this pair-programming methodology to Elixir and Livebook.

## What is PromptBuddy?

PromptBuddy is a Livebook Smart Cell that allows you to give prompts in the context of all the cells that precede it in the notebook. When you submit a prompt, it automatically includes the source code from all previous cells as context for the LLM, enabling contextual assistance as you develop your notebook.

## Features

- **Contextual LLM interaction**: Automatically includes all preceding cells as context
- **Streaming responses**: See the LLM's response in real-time as it generates
- **Multiple LLM support**: Works with any OpenRouter-compatible model via [ReqLLM](https://github.com/agentjido/req_llm)
- **Simple UI**: Clean form-based interface integrated into Livebook
- **Session introspection**: Automatically discovers and includes notebook context

## Installation

`kino_promptbuddy` can be installed by adding it to your list of dependencies in your Livebook setup section:

```elixir
Mix.install([
  {:kino_promptbuddy, "~> 0.0.1"}
])
```

## Configuration

Before using PromptBuddy, you need to configure an API key for your LLM provider. The library uses [OpenRouter](https://openrouter.ai) by default.

Add your OpenRouter API key to Livebook's Secrets menu (accessible from the navbar):
- Secret name: `LB_OPENROUTER_API_KEY`
- Value: Your OpenRouter API key

Then in your setup cell:

```elixir
if key = System.get_env("LB_OPENROUTER_API_KEY") do
  ReqLLM.put_key(:openrouter_api_key, key)
end
```

## Usage

1. Add the PromptBuddy package to your Livebook setup section
2. Configure your API key as described above
3. Insert a "Prompt Buddy" smart cell anywhere in your notebook
4. Type your prompt and submit
5. The LLM will receive context from all preceding cells and provide a contextual response

The smart cell will:
- Collect all cell sources from the beginning of the notebook up to (but not including) the current cell
- Use the first cell as a system message
- Use all subsequent cells as user messages
- Append your prompt as the final user message
- Stream the response back in real-time

## How It Works

PromptBuddy uses Livebook's introspection capabilities to:

1. Identify the current cell and session
2. Connect to the Livebook node via ERPC
3. Retrieve the notebook structure
4. Extract source code from all preceding cells
5. Build a conversation context for the LLM
6. Stream responses back through Kino frames

## Example

Once you have a few cells in your notebook (code, markdown, etc.), add a Prompt Buddy cell and ask questions like:
- "Explain what the code above does"
- "How can I optimize the function in the previous cell?"
- "Add error handling to the code"
- "What would be a good next step?"

The LLM will have full context of everything that came before.

## Documentation

Documentation can be found at <https://hexdocs.pm/kino_promptbuddy>.

## Development

To understand how PromptBuddy was built from scratch, check out the [from_scratch.livemd](nbs/from_scratch.livemd) notebook, which walks through the entire development process step-by-step.

## License

MIT
