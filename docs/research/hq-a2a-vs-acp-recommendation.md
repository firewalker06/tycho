# HQ Fit Analysis: A2A vs ACP

## Executive Summary

For HQ as it exists today, neither A2A nor ACP is a necessary core dependency. HQ is currently a local terminal control plane for project metadata and locally managed coding agents. Its main responsibilities are local process orchestration, run tracking, log inspection, and user interaction inside the TUI.

If HQ evolves to support remote agents, cross-machine orchestration, or interoperability with third-party agent systems, A2A is the better fit. ACP is conceptually relevant, but it is no longer the active standalone direction and has been incorporated into A2A. For new work, A2A is the stronger strategic choice.

## HQ Features and Capabilities

Based on the current codebase, HQ provides the following capabilities.

### 1. Project registry and grouping

HQ loads projects from configuration, including:

- project key,
- project name,
- group,
- local filesystem path,
- agent templates.

This behavior is defined in `config/hq.yml` and loaded through `HQ::Registry`.

### 2. Local project metadata inspection

For each configured project, HQ reads:

- Git branch,
- Git commit hash,
- dirty file count.

This is local repository introspection, not network agent communication.

### 3. Agent orchestration state

For managed agents, HQ:

- tracks run status,
- persists session memory,
- records structured results,
- exposes logs and follow-up prompts.

This is local orchestration state, not network agent interoperability.

### 4. Managed agent lifecycle

HQ creates and manages local coding agents per project. It supports:

- agent templates,
- agent creation and editing,
- local workspace targeting,
- sandbox mode selection,
- process start and stop,
- run history,
- structured result summaries,
- log file persistence.

### 5. Agent chat workflow

HQ lets the user continue interacting with a managed agent through a chat-like interface:

- user messages are appended to conversation history,
- the next agent run is started against the local workspace,
- recent messages and result summaries are displayed in the TUI,
- conversation state is persisted locally.

### 6. Local-first execution model

HQ runs agents as local `codex exec` processes. The current architecture is built around:

- local process spawning,
- local log files,
- local JSON persistence,
- polling process status by PID,
- reading a final structured result file from disk.

This is the key architectural fact for protocol fit. HQ does not currently depend on network-native remote agents.

## What HQ Actually Needs

From those features, HQ’s primary requirements are:

- reliable local process orchestration,
- durable run state,
- resumable or repeatable agent workflows,
- structured result capture,
- readable logs and summaries,
- clear human-in-the-loop interaction.

Those needs are only partially related to agent interoperability protocols.

## How A2A Maps to HQ

A2A is a protocol for agent-to-agent communication. It is strongest when independent agents need to discover each other, exchange structured context, manage tasks, stream updates, and handle asynchronous or interrupted workflows.

### What A2A would help with

If HQ expands beyond local `codex exec` management, A2A would map well to these future needs:

- remote agent discovery,
- standardized task lifecycle,
- streaming task progress,
- structured asynchronous updates,
- explicit capability advertisement,
- auth-aware agent interaction,
- cross-machine or cross-team interoperability.

### Why A2A aligns better with HQ’s mental model

HQ already has concepts similar to A2A:

- a managed agent,
- a run or task,
- status polling,
- follow-up interaction,
- structured result summaries,
- human input during an agent workflow.

A2A formalizes those ideas better than a simple request-response API. Its task model is especially relevant for HQ if agents become remote or long-lived.

### Why A2A is not required yet

Today HQ’s agents are local processes with local logs and local files. A2A would not simplify the current implementation unless HQ starts exposing agents over the network or consuming external agent services.

## How ACP Maps to HQ

ACP also addresses agent interoperability and shares several ideas with A2A:

- discovery,
- structured messages,
- run lifecycle,
- multimodal interaction,
- HTTP-native invocation.

### What ACP could theoretically help with

ACP could support:

- exposing HQ-managed agents through a protocol,
- invoking remote agents through a common run model,
- adding discovery and resumable remote workflows.

### Why ACP is the weaker choice

ACP’s main problem for HQ is strategic, not conceptual. Based on the research:

- ACP is no longer the active standalone direction,
- ACP has been incorporated into A2A,
- the original ACP repository has been archived.

That means ACP introduces migration risk without giving HQ a durable ecosystem advantage over A2A.

## Direct Comparison for HQ

### HQ need: local process orchestration

- A2A: not necessary
- ACP: not necessary

Neither protocol solves HQ’s current local process-management core.

### HQ need: persistent runs and statuses

- A2A: strong conceptual fit
- ACP: decent conceptual fit

Both help at the model level, but A2A is the active standard and has the stronger current execution model for future interoperability.

### HQ need: human-in-the-loop agent interaction

- A2A: strong fit
- ACP: moderate fit

A2A’s task states and interrupted workflow model are better aligned with agents that need clarification, authentication, or follow-up input.

### HQ need: remote or third-party agent interoperability

- A2A: strong fit
- ACP: weak-to-moderate fit

A2A is the better forward-looking choice because it is active and now absorbs ACP’s direction.

### HQ need: strategic long-term adoption

- A2A: strong fit
- ACP: poor fit

This is the clearest difference. If HQ adopts a protocol now, it should avoid choosing a protocol that has already effectively transitioned into another one.

## Recommendation

### Best fit today

The best fit for HQ today is its existing local execution model. HQ should keep using:

- local process spawning,
- local logs,
- local run persistence,
- local chat state,
- local status polling.

No agent interoperability protocol is required to make the current product work well.

### Best fit for future expansion

If HQ adds remote or interoperable agents, A2A is the right choice.

That is the recommendation for three reasons:

1. A2A matches HQ’s task-oriented agent lifecycle better.
2. A2A is the active protocol with forward momentum.
3. ACP has already been folded into A2A, so choosing ACP now creates avoidable future migration work.

### Recommendation against ACP

HQ should not adopt ACP for new work unless there is a hard compatibility requirement with an ACP-only external system.

## Practical Path for HQ

### Short term

Improve HQ’s current local agent model without introducing a protocol:

- better structured result capture,
- better user-input interruption handling,
- richer chat rendering,
- stronger run-state modeling.

### Medium term

Introduce an internal task model that resembles A2A concepts:

- explicit task states,
- explicit input-required state,
- structured questions,
- structured artifacts,
- event streaming or incremental updates.

This would improve HQ now and make a future A2A integration easier.

### Long term

If HQ becomes a multi-agent control plane, expose or consume agents through A2A rather than ACP.

## Conclusion

HQ is currently a local ops and agent-management cockpit, not an interoperability platform. That means neither A2A nor ACP is necessary at the core today.

If the product grows into remote or multi-agent orchestration, A2A is the correct protocol direction. It is more active, better aligned with task-oriented agent workflows, and strategically safer than ACP. ACP is still useful background context, but it is not the right protocol choice for new HQ investment.
