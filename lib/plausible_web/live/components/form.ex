defmodule PlausibleWeb.Live.Components.Form do
  @moduledoc """
  Generic components stolen from mix phx.new templates
  """

  use Phoenix.Component

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Examples

  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)

  attr(:type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
         range radio search select tel text textarea time url week)
  )

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"
  )

  attr(:errors, :list, default: [])
  attr(:checked, :boolean, doc: "the checked flag for checkbox inputs")
  attr(:prompt, :string, default: nil, doc: "the prompt for select inputs")
  attr(:options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2")
  attr(:multiple, :boolean, default: false, doc: "the multiple flag for select inputs")

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
         multiple pattern placeholder readonly required rows size step)
  )

  slot(:inner_block)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label :if={@label != nil and @label != ""} for={@id}>
        <%= @label %>
      </.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        {@rest}
      />
      <%= render_slot(@inner_block) %>
      <.error :for={msg <- @errors}>
        <%= msg %>
      </.error>
    </div>
    """
  end

  attr(:rest, :global)
  attr(:id, :string, required: true)
  attr(:class, :string, default: "")
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, default: "")

  def input_with_clipboard(assigns) do
    ~H"""
    <div class="my-4">
      <div>
        <.label for={@id}>
          <%= @label %>
        </.label>
      </div>
      <div class="relative mt-1">
        <.input
          id={@id}
          name={@name}
          value={@value}
          type="text"
          readonly="readonly"
          class={[@class, "pr-20"]}
          {@rest}
        />
        <a
          onclick={"var input = document.getElementById('#{@id}'); input.focus(); input.select(); document.execCommand('copy'); event.stopPropagation();"}
          href="javascript:void(0)"
          class="absolute flex items-center text-xs font-medium text-indigo-600 no-underline hover:underline top-2 right-4"
        >
          <Heroicons.document_duplicate class="pr-1 text-indigo-600 dark:text-indigo-500 w-5 h-5" />
          <span>
            COPY
          </span>
        </a>
      </div>
    </div>
    """
  end

  attr(:id, :any, default: nil)
  attr(:label, :string, default: nil)

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:password]",
    required: true
  )

  attr(:strength, :any)

  attr(:rest, :global,
    include: ~w(autocomplete disabled form maxlength minlength readonly required size)
  )

  def password_input_with_strength(%{field: field} = assigns) do
    {too_weak?, errors} =
      case pop_strength_errors(field.errors) do
        {strength_errors, other_errors} when strength_errors != [] ->
          {true, other_errors}

        {[], other_errors} ->
          {false, other_errors}
      end

    strength =
      if too_weak? and assigns.strength.score >= 3 do
        %{assigns.strength | score: 2}
      else
        assigns.strength
      end

    assigns =
      assigns
      |> assign(:too_weak?, too_weak?)
      |> assign(:field, %{field | errors: errors})
      |> assign(:strength, strength)

    ~H"""
    <.input field={@field} type="password" autocomplete="new-password" label={@label} id={@id} {@rest}>
      <.strength_meter :if={@too_weak? or @strength.score > 0} {@strength} />
    </.input>
    """
  end

  attr(:minimum, :integer, required: true)

  attr(:class, :any)
  attr(:ok_class, :any)
  attr(:error_class, :any)

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:password]",
    required: true
  )

  def password_length_hint(%{field: field} = assigns) do
    {strength_errors, _} = pop_strength_errors(field.errors)

    ok_class = assigns[:ok_class] || "text-gray-500"
    error_class = assigns[:error_class] || "text-red-500"
    class = assigns[:class] || ["text-xs", "mt-1"]

    color =
      if :length in strength_errors do
        error_class
      else
        ok_class
      end

    final_class = [color | class]

    assigns = assign(assigns, :class, final_class)

    ~H"""
    <p class={@class}>Min <%= @minimum %> characters</p>
    """
  end

  defp pop_strength_errors(errors) do
    Enum.reduce(errors, {[], []}, fn {_, meta} = error, {detected, other_errors} ->
      cond do
        meta[:validation] == :required ->
          {[:required | detected], other_errors}

        meta[:validation] == :length and meta[:kind] == :min ->
          {[:length | detected], other_errors}

        meta[:validation] == :strength ->
          {[:strength | detected], other_errors}

        true ->
          {detected, [error | other_errors]}
      end
    end)
  end

  attr(:score, :integer, default: 0)
  attr(:warning, :string, default: "")
  attr(:suggestions, :list, default: [])

  def strength_meter(assigns) do
    color =
      cond do
        assigns.score <= 1 -> ["bg-red-500", "dark:bg-red-500"]
        assigns.score == 2 -> ["bg-red-300", "dark:bg-red-300"]
        assigns.score == 3 -> ["bg-indigo-300", "dark:bg-indigo-300"]
        assigns.score >= 4 -> ["bg-indigo-600", "dark:bg-indigo-500"]
      end

    feedback =
      cond do
        assigns.warning != "" -> assigns.warning <> "."
        assigns.suggestions != [] -> List.first(assigns.suggestions)
        true -> nil
      end

    assigns =
      assigns
      |> assign(:color, color)
      |> assign(:feedback, feedback)

    ~H"""
    <div class="w-full bg-gray-200 rounded-full h-1.5 mb-2 mt-2 dark:bg-gray-700 mt-1">
      <div
        class={["h-1.5", "rounded-full"] ++ @color}
        style={["width: " <> to_string(@score * 25) <> "%"]}
      >
      </div>
    </div>
    <p :if={@score <= 2} class="text-sm text-red-500 phx-no-feedback:hidden">
      Password is too weak
    </p>
    <p :if={@feedback} class="text-xs text-gray-500">
      <%= @feedback %>
    </p>
    """
  end

  attr :id, :string, required: true
  attr(:name, :any)
  attr(:class, :string, default: "")
  attr(:value, :any, default: "")

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]",
    default: nil
  )

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
         multiple pattern placeholder readonly required rows size step)
  )

  def date_input(assigns) do
    value =
      if assigns.field do
        assigns.field.value
      else
        assigns.value
      end

    display_value =
      if value && value != "" do
        value
      else
        "(not set)"
      end

    assigns = assign(assigns, :display_value, display_value)

    ~H"""
    <div id={"#{@id}-wrapper"} phx-update="ignore">
      <label for={@id}>
        <span id={"#{@id}-display"} class="text-sm"><%= @display_value %></span>
        <span class="text-xs text-indigo-600">(change)</span>
      </label>
      <div class="relative sm:right-12 [&_.flatpickr-wrapper]:static">
        <.input
          type="hidden"
          id={@id}
          name={@name}
          value={@value}
          class="hidden"
          phx-hook="DatePicker"
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr(:for, :string, default: nil)
  slot(:inner_block, required: true)

  def label(assigns) do
    ~H"""
    <label for={@for} class="block font-medium dark:text-gray-100">
      <%= render_slot(@inner_block) %>
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot(:inner_block, required: true)

  def error(assigns) do
    ~H"""
    <p class="flex gap-3 text-sm leading-6 text-red-500 phx-no-feedback:hidden">
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
