# frozen_string_literal: true

require_relative "../lib/hq/domain/shell_command_classifier"

module ShellCommandClassifierTest
  module_function

  POSITIVE_CASES = {
    "semicolon" => "echo ready; sleep 60",
    "and-list" => "echo ready && sleep 60",
    "or-list" => "echo ready || sleep 60",
    "pipeline" => "echo ready | sleep 60",
    "stderr pipeline" => "echo ready |& sleep 60",
    "newline" => "echo ready\nsleep 60",
    "command substitution" => 'echo $(sleep 60)',
    "quoted command substitution" => 'echo "$(sleep 60)"',
    "nested command substitution" => 'echo "$(printf %s "$(sleep 60)")"',
    "legacy command substitution" => 'echo `sleep 60`',
    "process substitution" => "cat <(sleep 60)",
    "assignment substitution" => 'result=$(sleep 60)',
    "quoted assignment value" => 'MODE="safe" sleep 60',
    "quoted executable" => '"sleep" 60',
    "array substitution" => 'values=($(sleep 60))',
    "arithmetic substitution" => 'echo $((1 + $(sleep 60)))',
    "here-string substitution" => 'cat <<< "$(sleep 60)"',
    "unquoted heredoc substitution" => "cat <<EOF\n$(sleep 60)\nEOF",
    "unquoted heredoc backtick substitution" => "cat <<EOF\n`sleep 60`\nEOF",
    "unquoted heredoc quoted-looking substitution" => "cat <<EOF\n'$(sleep 60)'\nEOF",
    "if branch" => "if true; then sleep 60; fi",
    "wait in if condition" => "if sleep 60; then echo ready; fi",
    "elif branch" => "if false; then echo no; elif true; then sleep 60; fi",
    "while body" => "while true; do sleep 60; break; done",
    "for body" => "for item in one; do sleep 60; done",
    "case arm" => "case x in x) sleep 60;; esac",
    "brace group" => "{ sleep 60; }",
    "subshell" => "(sleep 60)",
    "function invoked later" => "pause() { sleep 60; }; pause",
    "keyword function invoked later" => "function pause { sleep 60; }; pause",
    "function substitution invoked later" => 'pause() { echo "$(sleep 60)"; }; pause',
    "function heredoc invoked later" => "pause() { cat <<EOF\n$(sleep 60)\nEOF\n}; pause",
    "subshell function invoked later" => "pause() ( sleep 60 ); pause",
    "function invoked in control structure" => "pause() { sleep 60; }; if true; then pause; fi",
    "command substitution inherits function" => 'pause() { sleep 60; }; echo $(pause)',
    "expanding heredoc inherits function" => "pause() { sleep 60; }; cat <<EOF\n$(pause)\nEOF",
    "explicit subshell inherits function" => "pause() { sleep 60; }; (pause)",
    "subshell local function invoked locally" => "(pause() { sleep 60; }; pause)",
    "brace group function leaks" => "{ pause() { sleep 60; }; }; pause",
    "ordered substitution sees prior function" => 'pause() { sleep 60; }; echo $(pause); echo ready',
    "nested inherited function" => 'outer() { inner() { sleep 60; }; inner; }; echo $(outer)',
    "nested brace function leaks" => "{ outer() { inner() { sleep 60; }; }; outer; }; inner",
    "nested control substitution" => 'if true; then echo "$(sleep 60)"; fi',
    "command after heredoc" => "cat <<EOF\nsleep 60\nEOF\nsleep 60",
    "command after nested heredoc" => "echo \"\$(cat <<EOF\n)\nEOF\nsleep 60\n)\"",
    "command after arithmetic shift" => "(( value = 1 << 2 ))\nsleep 60",
    "sudo" => "sudo sleep 60",
    "sudo reset timestamp" => "sudo -k sleep 60",
    "sudo options" => "sudo -n -- sleep 60",
    "nested wrappers" => "env RETRY=1 sudo -u root sleep 60",
    "command wrapper" => "command sleep 60",
    "time direct wait" => "time sleep 60",
    "time portable option direct wait" => "time -p sleep 60",
    "time function" => "pause() { sleep 60; }; time pause",
    "time portable option function" => "pause() { sleep 60; }; time -p pause",
    "external time direct wait" => "/usr/bin/time sleep 60",
    "nohup wrapper" => "nohup sleep 60",
    "nice wrapper" => "nice -n 5 sleep 60",
    "timeout wrapper" => "timeout 5 sleep 60",
    "nested shell" => "bash -lc 'echo ready; sleep 60'"
  }.freeze

  NEGATIVE_CASES = {
    "search argument" => "rg -n sleep docs/",
    "source string" => "ruby -e 'puts \\\"sleep 10\\\"'",
    "filename" => "cat sleep-notes.md",
    "single-quoted separator" => "echo 'ready; sleep 60'",
    "quoted control-word command" => '"then" sleep 60',
    "double-quoted pipeline" => "echo \"ready | sleep 60\"",
    "quoted newline" => "printf 'ready\\nsleep 60\\n'",
    "quoted substitution" => "echo '\$(sleep 60)'",
    "escaped double-quoted substitution" => 'echo "\$(sleep 60)"',
    "quoted process substitution" => 'echo "<(sleep 60)"',
    "arithmetic expression" => 'echo $((sleep + 60))',
    "arithmetic command" => '(( sleep += 60 ))',
    "arithmetic shift" => "(( value = 1 << 2 ))\necho ready",
    "array literal" => 'values=(sleep 60)',
    "search pattern" => "rg -n 'sleep 60|wait 1' docs/",
    "trailing comment" => "echo ready # sleep 60",
    "comment substitution" => 'echo ready # $(sleep 60)',
    "comment line" => "# sleep 60\necho ready",
    "plain heredoc body" => "cat <<EOF\nsleep 60\nEOF",
    "quoted heredoc body" => "cat <<'EOF'\necho \$(sleep 60)\nEOF",
    "quoted heredoc substitution" => "cat <<'EOF'\n$(sleep 60)\nEOF",
    "quoted heredoc backtick substitution" => "cat <<\"EOF\"\n`sleep 60`\nEOF",
    "backslash-quoted heredoc substitution" => "cat <<\\EOF\n$(sleep 60)\nEOF",
    "escaped unquoted heredoc substitution" => "cat <<EOF\n\\$(sleep 60)\nEOF",
    "tab-stripped heredoc body" => "cat <<-EOF\n\tsleep 60\nEOF",
    "multiple heredoc bodies" => "cat <<FIRST <<SECOND\nsleep 60\nFIRST\nwait\nSECOND",
    "heredoc inside substitution" => "echo \"\$(cat <<EOF\nsleep 60\nEOF\n)\"",
    "parenthesis in nested heredoc" => "echo \"\$(cat <<EOF\n) sleep 60\nEOF\n)\"",
    "heredoc delimiter" => "cat <<sleep\nready\nsleep",
    "case pattern" => "case x in sleep) echo ready;; esac",
    "later case pattern" => "case x in x) echo first;; sleep) echo second;; esac",
    "conditional operands" => "if [[ sleep == sleep ]]; then echo ready; fi",
    "for values" => 'for item in sleep 60; do echo "$item"; done',
    "for variable" => "for sleep in one; do echo ready; done",
    "function name" => "sleep() { echo ready; }",
    "function keyword name" => "function sleep { echo ready; }",
    "dormant function body" => "pause() { sleep 60; }",
    "dormant keyword function body" => "function pause { sleep 60; }",
    "dormant function substitution" => 'pause() { echo "$(sleep 60)"; }',
    "dormant function expanding heredoc" => "pause() { cat <<EOF\n$(sleep 60)\nEOF\n}",
    "dormant subshell function body" => "pause() ( sleep 60 )",
    "subshell function does not leak" => "(pause() { sleep 60; }); pause",
    "substitution function does not leak" => 'echo $(pause() { sleep 60; }); pause',
    "heredoc function does not leak" => "cat <<EOF\n$(pause() { sleep 60; })\nEOF\npause",
    "later function unavailable to earlier substitution" => 'echo $(pause); pause() { sleep 60; }',
    "later function unavailable to earlier heredoc" => "cat <<EOF\n$(pause)\nEOF\npause() { sleep 60; }",
    "nested subshell function does not leak" => "(outer() { inner() { sleep 60; }; }; outer); inner",
    "nested non-wait substitution" => 'printf %s "$(printf sleep)"',
    "sudo argument" => "sudo printf 'sleep 60\\n'",
    "command lookup" => "command -p -v sleep",
    "command does not invoke function" => "pause() { sleep 60; }; command pause",
    "time command does not invoke function" => "pause() { sleep 60; }; time command pause",
    "time option command does not invoke function" => "pause() { sleep 60; }; time -p command pause",
    "command time does not invoke function" => "pause() { sleep 60; }; command time pause",
    "quoted time does not invoke function" => 'pause() { sleep 60; }; "time" pause',
    "time non-wait command" => "time printf 'sleep 60\\n'",
    "time help does not invoke function" => "pause() { sleep 60; }; time --help pause",
    "time version does not invoke function" => "pause() { sleep 60; }; time --version pause",
    "time GNU short option does not invoke function" => "pause() { sleep 60; }; time -f elapsed pause",
    "time GNU long option does not invoke function" => "pause() { sleep 60; }; time --format elapsed pause",
    "time GNU inline option does not invoke function" => "pause() { sleep 60; }; time --format=elapsed pause",
    "time delimiter does not invoke function" => "pause() { sleep 60; }; time -- pause",
    "time GNU short option does not execute direct wait" => "time -f elapsed sleep 60",
    "time delimiter does not execute direct wait" => "time -- sleep 60",
    "wrapper help" => "env --help sleep",
    "wrapper version" => "sudo -V sleep"
  }.freeze

  def run!
    classifier = HQ::ShellCommandClassifier.new(blocking_commands: %w[sleep usleep wait])
    assert_cases(classifier, POSITIVE_CASES, expected: true)
    assert_cases(classifier, NEGATIVE_CASES, expected: false)
    puts "shell_command_classifier_test: ok"
  end

  def assert_cases(classifier, cases, expected:)
    cases.each do |name, command|
      detected = classifier.blocking_wait?(command)
      assert(detected == expected,
             "expected #{name} to #{expected ? 'count' : 'remain ignored'}: #{command.inspect}")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

ShellCommandClassifierTest.run! if $PROGRAM_NAME == __FILE__
