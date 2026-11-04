# frozen_string_literal: true

require "open3"

root = File.expand_path("..", __dir__)
script = <<~'JAVASCRIPT'
  const assert = require("node:assert/strict");
  const { validateConfig, scheduleConfig, renderReport } = require("./bin/remote-ui-interaction-report");
  validateConfig(require("./config/interaction-tests/schedule-resume.json"));
  const scenario = () => ({
    url: "http://localhost:7373/",
    steps: [{ action: "measure", name: "Open panel", trigger: { action: "click", selector: "#open" },
      expect: { selector: "#panel", visible: true }, screenshot: "#card" }]
  });
  const valid = validateConfig(scenario());
  assert.equal(valid.steps[0].withinMs, 100);
  assert.equal(valid.steps[0].timeoutMs, 30000);
  assert.equal(scheduleConfig("http://localhost:7373", "schedule", 1000, 100).steps[1].trigger.text, "Resume");
  for (const invalid of [
    { ...scenario(), token: "do-not-store" },
    { ...scenario(), url: "http://user:secret@localhost:7373/" },
    { ...scenario(), url: "http://localhost:7373/?token=secret" },
    { ...scenario(), steps: [...scenario().steps, { action: "open", url: "https://other.invalid/" }] },
    { ...scenario(), steps: [...scenario().steps, { action: "execute", code: "unsafe" }] },
    { ...scenario(), steps: [{ ...scenario().steps[0], expect: { selector: "#panel", visible: true, text: "Ready" } }] },
    { ...scenario(), steps: [{ ...scenario().steps[0], withinMs: 30000 }] },
    { ...scenario(), steps: [{ ...scenario().steps[0], expect: { selector: "#panel", attribute: null } }] },
    { ...scenario(), steps: [{ ...scenario().steps[0], screenshot: "" }] },
    { ...scenario(), steps: [{ action: "click", selector: "#open" }] }
  ]) assert.throws(() => validateConfig(invalid));
  for (const expect of [{selector:"#state",text:""}, {selector:"#state",visible:false}, {selector:"#state",attribute:{name:"aria-busy",value:null}}]) {
    validateConfig({ ...scenario(), steps: [{ ...scenario().steps[0], expect }] });
  }
  const navigation = validateConfig({ ...scenario(), steps: [{action:"open",url:"/ui#settings"}, ...scenario().steps] });
  assert.equal(navigation.steps[0].url, "http://localhost:7373/ui#settings");
  const report = renderReport({name:"<script>bad</script>",url:valid.url,capturedAt:"test",steps:[],measurements:[{
    name:"<img src=x>",images:[],result:{outcome:"observed",immediate:true,immediateMs:100,events:[{ms:0,text:"<script>bad</script>"}],requests:[]}
  }]});
  assert.ok(report.includes("&lt;script&gt;bad&lt;/script&gt;"));
  assert.ok(!report.includes("<script>bad</script>"));
  console.log("interaction report: configuration, navigation boundaries, expectations, and HTML escaping passed");
JAVASCRIPT

out, err, status = Open3.capture3("node", "-e", script, chdir: root)
raise "#{out}\n#{err}" unless status.success?

puts out
