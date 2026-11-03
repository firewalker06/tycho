# frozen_string_literal: true

require_relative "remote_server_test"

module PromptReceiptTest
  module_function

  def run!
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new)
      created = service.create_agent("project_key" => "web", "prompt" => "Synthetic only")
      key = created.fetch(:key)
      check(service.agents.find { |agent| agent[:key] == key }[:prompt_receipt_version] == 1, "catalog reconciliation retains receipt capability")
      server_id = created.fetch(:delegation).fetch(:server_id)
      legacy = service.submit_prompt(key, "prompt" => "Legacy body", "start" => false)
      check(legacy[:agent] && legacy[:conversation], "legacy callers keep their full response")
      service.define_singleton_method(:agent_payload) { |*| raise "receipt built agent projection" }
      service.define_singleton_method(:conversation) { |*| raise "receipt built conversation projection" }
      attrs = {
        "response_mode" => "receipt", "expected_server_id" => server_id,
        "client_request_id" => "client-receipt-queue", "prompt" => "Synthetic queued only", "delay" => 3600
      }
      response = service.submit_prompt(key, attrs)
      receipt = response.fetch(:receipt)
      check(receipt[:version] == 1 && receipt[:accepted] == true && receipt[:outcome] == "queued", "explicit queued receipt")
      check(receipt[:agent_key] == key && receipt[:server_id] == server_id && receipt[:client_request_id] == attrs["client_request_id"], "receipt destination binding")
      entry = receipt.fetch(:queue_entry)
      check(entry["id"] == attrs["client_request_id"] && entry["source"] == "user", "canonical queue identity and source")
      check(entry.key?("authority") && entry.key?("not_before"), "explicit authority and eligibility fields")
      check(Time.parse(entry.fetch("not_before")) > Time.now && !receipt[:revision].empty?, "future eligibility and revision")
      check(!response.key?(:agent) && !response.key?(:conversation) && !entry.key?("prompt"), "receipt omits display projections and prompt")
      reader = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new)
      proofs = reader.agent(key)[:prompt_acceptances]
      check(proofs&.any? { |proof| proof.dig(:receipt, :client_request_id) == attrs["client_request_id"] }, "a fresh service read proves the original accepted ID without another write")
      check(proofs.first[:receipt] == receipt.merge(replayed: true), "detail exposes the same bound queued proof")
      check(!JSON.generate(proofs).include?("fingerprint") && !JSON.generate(proofs).include?("Synthetic queued"), "proof excludes private payload and fingerprint")
      replay = service.submit_prompt(key, attrs).fetch(:receipt)
      check(replay[:replayed] && replay[:outcome] == "queued", "queued replay")
      service.instance_variable_get(:@agent_store).read_prompt_queue!(key, read_at: Time.now + 3601)
      processed = service.submit_prompt(key, attrs).fetch(:receipt)
      check(processed[:replayed] && processed[:outcome] == "replayed" && processed[:queue_entry].nil?, "read queue replay cannot enqueue again")
      delivered_proofs = service.send(:prompt_acceptance_proofs, service.send(:find_agent_reference!, key))
      check(delivered_proofs.first.dig(:receipt, :outcome) == "replayed", "consumed work has a durable proof without re-enqueue")
      check(service.send(:find_agent_reference!, key).prompt_queue.empty?, "processed retry preserves empty queue")
      conflict(service, key, attrs.merge("prompt" => "Different intent"), 409)
      conflict(service, key, attrs.merge("expected_server_id" => "other-server"), 409)
      conflict(service, key, attrs.merge("client_request_id" => "invalid"), 400)
      immediate = attrs.reject { |name, _| name == "delay" }.merge("client_request_id" => "client-receipt-immediate", "start" => false)
      accepted = service.submit_prompt(key, immediate).fetch(:receipt)
      check(accepted[:outcome] == "accepted" && !accepted[:replayed], "immediate acceptance is distinct from queued")
      check(service.submit_prompt(key, immediate).dig(:receipt, :outcome) == "replayed", "immediate retry does not append")
      service.archive_agent(key)
      conflict(service, key, immediate, 409)
    end
    guard_checks
    puts "prompt_receipt_test: ok"
  end

  def guard_checks
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      service = HQ::RemoteService.new(registry:, web_push_notifier: RemoteServerTest::RecordingPushNotifier.new)
      parent = service.create_agent("project_key" => "web", "prompt" => "Synthetic parent")
      child = service.create_agent("project_key" => "web", "prompt" => "Synthetic child", "parent_agent_key" => parent[:key])
      key = child[:key]
      attrs = { "response_mode" => "receipt", "expected_server_id" => child.dig(:delegation, :server_id),
                "client_request_id" => "client-authority-user", "prompt" => "Takeover message", "delay" => 3600 }
      user = service.submit_prompt(key, attrs).fetch(:receipt)
      check(user.dig(:authority, "owner") == "user" && user.dig(:authority, "generation").positive?, "takeover authority is canonical")
      parent_attrs = attrs.merge("client_request_id" => "client-authority-parent", "parent_agent_key" => parent[:key])
      parent_receipt = service.submit_prompt(key, parent_attrs).fetch(:receipt)
      check(parent_receipt.dig(:authority, "owner") == "parent", "parent declaration restores delegation")
      replay = service.submit_prompt(key, attrs).fetch(:receipt)
      check(replay[:authority] == user[:authority], "replay retains original acceptance authority")
      live = service.instance_variable_get(:@agent_store).delegation_coordinator.ownership_stamp(key)
      check(live["owner"] == "parent" && live["generation"] == parent_receipt.dig(:authority, "generation"), "replay does not take ownership again")

      ordinary = service.create_agent("project_key" => "web", "prompt" => "Inquiry guard fixture")
      key = ordinary[:key]
      attrs = { "response_mode" => "receipt", "expected_server_id" => ordinary.dig(:delegation, :server_id),
                "client_request_id" => "client-rejected-inquiry", "prompt" => "Stale inquiry send", "retire_inquiry_id" => "stale" }
      rejection = service.submit_prompt(key, attrs)
      check(rejection.dig(:rejection, :client_request_id) == attrs["client_request_id"], "inquiry mismatch produces a bound rejection")
      check(service.submit_prompt(key, attrs)[:rejection] == rejection[:rejection], "rejection is fenced for exact retry")
      accepted = attrs.reject { |name, _| name == "retire_inquiry_id" }.merge("client_request_id" => "client-accepted-after-rejection")
      RemoteServerTest.with_stubbed_agent_start do
        receipt = service.submit_prompt(key, accepted.merge("start" => true)).fetch(:receipt)
        check(receipt[:outcome] == "accepted", "accepted start does not require a queued label")
      end
      # Once accepted, a retry must not revalidate a context snapshot that can be removed later.
      service.define_singleton_method(:render_prompt_pull_request_contexts) { |*| raise "must not revalidate accepted context" }
      check(service.submit_prompt(key, accepted.merge("start" => true)).dig(:receipt, :outcome) == "replayed", "accepted retry bypasses stale input projection")
      record = service.send(:find_agent_reference!, key)
      check(record.prompt_receipts.values.all? { |receipt| !receipt.key?("prompt") && !receipt.key?("attachments") }, "durable receipt index stores no payload")
    end
  end

  def conflict(service, key, attrs, status)
    service.submit_prompt(key, attrs)
    raise "expected rejection #{status}"
  rescue HQ::RemoteService::Error => e
    check(e.status == status, "expected #{status}, got #{e.status}")
  end

  def check(value, message)
    raise message unless value
  end
end

PromptReceiptTest.run! if $PROGRAM_NAME == __FILE__
