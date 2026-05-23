# Install Charm Ruby Gems

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

Installs the necessary Charm Ruby gems for TUI development, styling, components, markdown rendering, shell scripting, animations, charts, and mouse tracking.

```ruby
# Gemfile

# Core TUI framework
gem "bubbletea"

# Styling
gem "lipgloss"

# Components
gem "bubbles"

# Markdown rendering
gem "glamour"

# Shell scripts
gem "gum"

# Animations
gem "harmonica"

# Charts
gem "ntcharts"

# Mouse tracking
gem "bubblezone"

```

--------------------------------

## Create Terminal Form with Huh (Ruby)

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

Demonstrates how to create an interactive terminal form using the Huh gem. It defines input fields and select options, applies a Charm theme, and displays the form. The input values are then accessed after the form runs.

```ruby
require "huh"

form = Huh.form(
  Huh.group(
    Huh.input
      .key("name")
      .title("What's your name?")
      .placeholder("Enter name..."),

    Huh.select
      .key("color")
      .title("Favorite color?")
      .options(*Huh.options(
        "Red", "Green", "Blue"
      ))
  )
).with_theme(Huh::Themes.charm)

form.run

puts "Hello, #{form["name"]}!"
```

--------------------------------

## Create Real-time Charts with Ntcharts (Ruby)

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

Demonstrates the creation of real-time, updating charts in the terminal using the Ntcharts gem. It initializes a streamline chart, continuously pushes new data points (sine wave values), clears the screen, and re-renders the chart.

```ruby
require "ntcharts"

chart = Ntcharts::Streamlinechart.new(60, 12)

loop do
  chart.push(Math.sin(Time.now.to_f) * 4 + 5)

  print "\e[H\e[2J"
  puts chart.render
  sleep 0.1
end
```

--------------------------------

### Render Markdown with Glamour (Ruby)

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

Illustrates how to render Markdown text to the terminal with styling using the Glamour gem. It takes a Markdown string, applies a dark style, sets the width, and enables emoji rendering.

````ruby
require "glamour"

markdown = <<~MD
  # Hello Glamour :sparkles:

  This is **bold** and *italic*.

  - Item one
  - Item two
  - Item three

  ```ruby

  puts "Hello, World!"

  ```

MD

puts Glamour.render(markdown,
  style: "dark",
  width: 80,
  emoji: true
)
````

--------------------------------

### Create Styled Table with Lipgloss (Ruby)

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

Shows how to generate a styled table in the terminal using the Lipgloss gem. It defines table headers and rows, sets a rounded border style, and renders the table to the console.

```ruby
require "lipgloss"

headers = ["Name", "Language", "Stars"]

rows = [
  ["bubbletea", "Ruby", "✨"],
  ["lipgloss", "Ruby", "💄"],
  ["glamour", "Ruby", "✨"]
]

table = Lipgloss::Table.new
  .headers(headers)
  .rows(rows)
  .border(:rounded)

puts table.render
```

--------------------------------

### Create a Basic Bubbletea TUI

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

A simple Bubbletea application that displays a styled 'Hello, Charm Ruby!' message and allows the user to quit by pressing 'q'. It utilizes Lipgloss for styling the message with rounded borders and padding.

```ruby
require "bubbletea"
require "lipgloss"

class HelloWorld
  include Bubbletea::Model

  def initialize
    @style = Lipgloss::Style.new
      .border(:rounded)
      .border_foreground("#7D56F4")
      .padding(1, 2)
  end

  def init = [self, nil]

  def update(message)
    case message
    when Bubbletea::KeyMessage
      return [self, Bubbletea.quit] if message.to_s == "q"
    end

    [self, nil]
  end

  def view
    @style.render("Hello, Charm Ruby!\n\nPress q to quit")
  end
end

Bubbletea.run(HelloWorld.new)

```

--------------------------------

### Implement a Spinner Component in Bubbletea

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

A Bubbletea TUI application demonstrating the use of the Bubbles Spinner component. It displays a loading spinner and a 'Loading...' message, allowing the user to quit by pressing 'q' or 'ctrl+c'.

```ruby
require "bubbletea"
require "bubbles"

class LoadingApp
  include Bubbletea::Model

  def initialize
    @spinner = Bubbles::Spinner.new
  end

  def init
    [self, @spinner.tick]
  end

  def update(message)
    case message
    when Bubbletea::KeyMessage
      case message.to_s
      when "q", "ctrl+c"
        return [self, Bubbletea.quit]
      end
    end

    @spinner, command = @spinner.update(message)

    [self, command]
  end

  def view
    "#{@spinner.view} Loading..."
  end
end

Bubbletea.run(LoadingApp.new)

```

--------------------------------

### Build a Counter TUI with Styling

Source: [charm-ruby.dev](https://charm-ruby.dev/index)

A Bubbletea TUI application that implements a counter. Users can increment or decrement the count using the up and down arrow keys, and quit by pressing 'q' or 'ctrl+c'. The count is displayed with bold styling.

```ruby
require "bubbletea"
require "lipgloss"

class Counter
  include Bubbletea::Model

  def initialize
    @count = 0
    @style = Lipgloss::Style.new
      .bold(true)
      .foreground("#FF6B6B")
  end

  def update(message)
    case message
    when Bubbletea::KeyMessage
      case message.to_s
      when "q", "ctrl+c"
        return [self, Bubbletea.quit]
      when "up" then @count += 1
      when "down" then @count -= 1
      end
    end

    [self, nil]
  end

  def view
    @style.render("Count: #{@count}\n\nPress q to quit")
  end
end

Bubbletea.run(Counter.new)

```

=== COMPLETE CONTENT === This response contains all available snippets from this library. No additional content exists. Do not make further requests.
