# ADR 001: Agent Delegation and Takeover

Status: accepted for implementation on 2026-08-19

## Context

Tycho currently links a child agent to a parent and can wake the parent when the child reports. A user may also work directly with the child. If both paths remain active, the parent can react to stale or conflicting reports after the user has taken control.

The design must not depend on an agent following an instruction about whom it may contact. Tycho owns the relationship state and message routing outside the agent conversation.

## Decisions

### A direct user prompt triggers Takeover

Any prompt sent directly by the user to a delegated child atomically changes the relationship from Delegation to Takeover before Tycho delivers the prompt. The run produced by that prompt therefore cannot report to or wake the former parent.

This rule also applies when the user directly answers a clarification from the child. To preserve Delegation, the user must communicate through the parent instead.

Takeover becomes effective when Tycho accepts the direct user prompt, even if another child run is active and the prompt must wait. Tycho immediately suppresses undelivered reports and does not create new reports for the superseded delegation. Reports already delivered into parent history remain immutable.

### A parent prompt restores Delegation

Takeover is not sticky. A later prompt from the parent to the child atomically restores Delegation before Tycho delivers that prompt. Ownership therefore follows the source of the latest prompt delivered to the child: the user or the parent.

This supports a natural conversational flow. The user can take over by talking to the child, then talk to the parent and allow the parent to delegate further work to the same child.

Merely prompting the parent does not change any child relationship. Delegation is restored only for a child that actually receives a resulting parent-to-child prompt; sibling relationships remain unchanged.

If the child is waiting on an `input_required` response, an accepted parent-to-child prompt cancels that pending inquiry and removes its answer-required form before the prompt proceeds. The new prompt is not interpreted as an answer to the old inquiry.

### Reports are the only upward channel

A child cannot address a prompt to its parent or any other ancestor. It also cannot create a delegation targeting an ancestor. Tycho rejects both operations using relationship provenance and ancestry, independent of the instructions seen by either agent.

Only Tycho's lifecycle coordinator can route a report upward. The relationship fixes the recipient; the child contributes result content but cannot select the report target or directly invoke the parent. Reports may wake the recorded parent while the relationship is in Delegation. They are suppressed during Takeover.

### Each completed child run produces one report

While a relationship is in Delegation, Tycho produces at most one upward report after every completed child run. This includes successful, partial, failed, blocked, and input-required outcomes. The report wakes the recorded parent.

Streaming output is observable but does not produce reports or wake the parent. The completed run is the deterministic callback boundary.

Each report uses a stable relationship-and-run identity and is delivered at most once. Its fixed envelope identifies the child, run, ownership generation, status, summary, inquiry, and attachments. Delivery schedules one parent wake; if the parent is busy, Tycho queues that wake until the parent is available.

### Report eligibility is bound to an ownership generation

The relationship advances to a new ownership generation only when its owner changes between parent and user. Repeated prompts from the current owner remain in the same generation.

Tycho stamps each accepted run trigger with the current owner and generation. A completed run reports only when its stamp names the parent as owner and still matches the relationship's current generation. This includes a run triggered by a descendant's system report while the relationship remains delegated.

A direct user prompt supersedes the parent-owned generation immediately, so active and queued runs stamped with that generation cannot report afterward. Conversely, a user-owned run never becomes reportable merely because the parent reclaims the child before that run finishes. This prevents results from crossing ownership boundaries during queued or overlapping work.

### Takeover is local to one relationship edge

In a nested graph such as `A → B → C`, a direct user prompt to B changes only the `A → B` relationship to Takeover. The `B → C` delegation remains intact, so C can continue to report to and wake B.

A system report from C does not change B's ownership relative to A. If B completes a report-triggered run while `A → B` is in Takeover, Tycho does not report that run onward to A. Ownership never changes an entire descendant subtree implicitly.

### Agent actions carry verified provenance

Each agent run receives a short-lived capability bound to that agent's key. Agent-originated prompt and delegation operations must present that capability, so Tycho can verify the source against the relationship graph and reject upward operations.

User channels authenticate separately, and lifecycle reports use an internal coordinator path. Agent environments do not receive broader user or server credentials that could impersonate another actor. Caller-supplied actor labels are not trusted.

## Consequences

- The takeover trigger is simple and observable: direct user input means user ownership.
- Ownership changes before execution, avoiding a race between the prompt and report routing.
- Directly helping a delegated child is an intentional ownership change, not a transparent aside.
- A later parent prompt can reclaim the child without a separate reconnect control.
- Upward callbacks remain possible without exposing a general child-to-ancestor prompt channel.
- Concurrent and queued runs cannot report across a change in ownership.
- Nested delegation remains useful without coupling ownership across the entire tree.
- The upward-channel rule is enforceable because actor identity is verified outside the model.
- A parent prompt can supersede an obsolete inquiry without requiring the child form to be answered first.

## State chart

```mermaid
stateDiagram-v2
    [*] --> Delegation: Parent prompt accepted

    state "Delegation\nowner: parent" as Delegation
    state "Takeover\nowner: user" as Takeover

    Delegation --> Delegation: Parent prompt accepted\nsame generation
    Delegation --> Delegation: Eligible run completes\nreport once and wake parent
    Delegation --> Takeover: Direct user prompt accepted\nadvance generation; suppress old reports

    Takeover --> Takeover: Direct user prompt accepted\nsame generation; no parent report
    Takeover --> Takeover: Run completes\nno parent report
    Takeover --> Delegation: Parent prompt accepted\nadvance generation; cancel answer-required form

    note right of Delegation
      Reports are the only upward channel.
      Child prompts and reverse delegation
      to ancestors are rejected.
    end note

    note right of Takeover
      Descendant delegation edges remain intact.
      Already delivered reports remain immutable.
    end note
```
