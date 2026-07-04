# Agent2Agent (A2A) Protocol Research

## Executive Summary

Agent2Agent (A2A) is an open protocol for communication and interoperability between independent AI agents. Its purpose is to let agents built by different teams, in different frameworks, and running on different infrastructure collaborate without exposing their internal memory, tools, or implementation details.

A2A is not a tool-calling protocol. It is an agent-to-agent protocol. That distinction matters. A2A standardizes how agents discover each other, advertise capabilities, exchange messages and artifacts, manage long-running tasks, stream updates, and handle asynchronous notifications. In the current ecosystem, it is best understood as the protocol layer for peer agent collaboration.

As of April 7, 2026, the official A2A documentation identifies the latest released specification as version `1.0.0`. The project was originally developed by Google and is now under the Linux Foundation. Official A2A materials also state that IBM ACP has been incorporated into A2A, which makes A2A the more relevant strategic standard for new adoption.

## Why A2A Exists

The protocol addresses a recurring systems problem:

- agent systems are often built with incompatible frameworks,
- agents need to collaborate across organizational and runtime boundaries,
- tool-calling alone is too limited for multi-turn delegation and negotiation,
- bespoke integrations do not scale across many agents.

A2A’s answer is to model an agent as a service that can be discovered and engaged through a common interaction contract. That contract supports richer collaboration than a simple function call: an agent can accept a task, work on it asynchronously, ask for more input, return artifacts, and emit status changes over time.

## Current Project Status

This is the most important current-context point for anyone evaluating the protocol:

- A2A is currently the active open standard in this area.
- The official docs say it was originally developed by Google and then donated to the Linux Foundation.
- The official specification page lists `1.0.0` as the latest released version.
- Official A2A materials explicitly say IBM ACP has been incorporated into A2A.

That makes A2A materially different from ACP in present-day adoption terms. ACP is now mainly useful as background and migration context; A2A is the live protocol to evaluate for greenfield work.

## Core Design Goals

The specification states that A2A is designed to let agents:

- discover each other’s capabilities,
- negotiate interaction modalities such as text, files, and structured data,
- manage collaborative tasks,
- securely exchange information without sharing internal state, memory, or tools.

These goals imply a few strong architectural preferences.

### 1. Opaque collaboration

A2A assumes an agent should be able to collaborate without exposing internals. This is a major design choice. It treats agents as autonomous systems, not as transparent tool wrappers.

### 2. Task-oriented interaction

The protocol is built around tasks rather than single stateless calls. This fits realistic agent workflows better, especially when work spans multiple steps, humans, or systems.

### 3. Multi-turn and long-running execution

A2A expects tasks to evolve over time. It includes task retrieval, streaming updates, resumption patterns, and push notifications for asynchronous work.

### 4. Rich data exchange

A2A supports messages, structured parts, and artifacts rather than assuming all communication is plain text.

### 5. Binding flexibility

The protocol has a standard JSON-RPC binding over HTTP(S), but the spec also allows other bindings such as gRPC or custom transports as long as they are declared in the Agent Card and preserve A2A semantics.

## High-Level Architecture

At a practical level, A2A involves:

- a client agent or application that initiates contact,
- a server agent that exposes A2A-compliant capabilities,
- an Agent Card used for discovery,
- a task lifecycle used to represent work,
- messages and artifacts used to carry content and results.

This means a typical A2A flow looks like:

1. Discover an agent through its Agent Card.
2. Inspect its skills, capabilities, interfaces, and security requirements.
3. Send a message to initiate or continue a task.
4. Receive either an immediate message response or a task handle.
5. Track progress by polling, subscribing to streams, or receiving push notifications.
6. Handle interrupted states such as additional input required or authentication required.

## Core Objects

### Agent Card

The `AgentCard` is A2A’s discovery document. It is the self-describing manifest that tells clients what an agent is and how to interact with it.

According to the official specification, an `AgentCard` includes:

- `name`,
- `description`,
- `supportedInterfaces`,
- `provider`,
- `version`,
- `documentationUrl`,
- `capabilities`,
- `securitySchemes`,
- `securityRequirements`,
- `defaultInputModes`,
- `defaultOutputModes`,
- `skills`,
- optional signatures and icon metadata.

This is a strong part of the protocol design. It lets clients reason about an agent before invoking it, and it gives the ecosystem a standard discovery surface.

### Supported Interfaces

The `supportedInterfaces` field is particularly important because it separates the protocol contract from any single transport binding. An agent can advertise multiple ways to interact with it, each with:

- a target URL,
- a protocol binding,
- a protocol version.

The spec’s examples include bindings such as `JSONRPC`, `GRPC`, and `HTTP+JSON`.

### Capabilities

The `capabilities` object describes optional protocol features. In the current spec it includes flags such as:

- `streaming`,
- `pushNotifications`,
- `extensions`,
- `extendedAgentCard`.

This capability model matters because A2A uses explicit negotiation. Clients should not assume advanced features exist unless the Agent Card declares them.

### Skills

`skills` are descriptive capability entries in the Agent Card. A skill has an ID, name, description, tags, example prompts, supported media types, and optional security requirements.

Skills are not low-level function signatures. They are intentionally higher-level and descriptive, which fits A2A’s emphasis on agent collaboration rather than narrow RPC-style method invocation.

### Message

The `Message` object is the core content carrier. It includes:

- `messageId`,
- optional `contextId`,
- optional `taskId`,
- `role`,
- `parts`,
- optional metadata,
- optional extensions,
- optional referenced task IDs.

This structure lets messages participate in both conversational and task-oriented workflows.

### Parts and Artifacts

The spec treats messages and outputs as structured, multimodal objects. A `Part` represents one piece of content inside a message or artifact. An `Artifact` represents task output.

This is operationally important. It means A2A can carry:

- plain text,
- files,
- structured JSON,
- composite outputs with multiple parts,
- streamed artifact updates while a task is still running.

That makes it more suitable for serious agent collaboration than protocols that assume “chat text in, chat text out.”

### Task

The `Task` is the central unit of action in A2A. The spec defines a task as having:

- an `id`,
- an optional `contextId`,
- a `status`,
- optional `artifacts`,
- optional `history`,
- optional metadata.

This is the protocol’s execution backbone. Instead of forcing all work into immediate request/response semantics, A2A gives collaboration a durable lifecycle.

## Task Lifecycle

The A2A specification defines explicit task states:

- `TASK_STATE_SUBMITTED`,
- `TASK_STATE_WORKING`,
- `TASK_STATE_COMPLETED`,
- `TASK_STATE_FAILED`,
- `TASK_STATE_CANCELED`,
- `TASK_STATE_INPUT_REQUIRED`,
- `TASK_STATE_REJECTED`,
- `TASK_STATE_AUTH_REQUIRED`.

These states are one of the protocol’s strongest ideas.

### Why the lifecycle matters

The interrupted states are especially useful:

- `TASK_STATE_INPUT_REQUIRED` allows an agent to pause and request more information.
- `TASK_STATE_AUTH_REQUIRED` allows an agent to request authentication before continuing.

This makes A2A a better fit for realistic enterprise workflows than simpler protocols that only model success or failure.

## Core Operations

The v1.0 specification defines a set of protocol operations centered on sending messages and managing tasks.

Key operations include:

- `SendMessage`,
- `SendStreamingMessage`,
- `GetTask`,
- `ListTasks`,
- `CancelTask`,
- `SubscribeToTask`,
- `CreateTaskPushNotificationConfig`,
- `GetTaskPushNotificationConfig`,
- `ListTaskPushNotificationConfigs`,
- `DeleteTaskPushNotificationConfig`,
- `GetExtendedAgentCard`.

This API surface is broader than a simple chat API. It is designed for discoverable, manageable, long-running agent collaboration.

## Transport Model

### Standard binding

The official specification defines a JSON-RPC 2.0 binding over HTTP(S) with Server-Sent Events for streaming. The protocol requirements section explicitly calls for:

- JSON-RPC 2.0 over HTTP(S),
- `application/json` for requests and responses,
- SSE for streaming,
- HTTP headers for A2A service parameters such as version and extensions.

This is a pragmatic design. JSON-RPC gives method structure, HTTP keeps hosting familiar, and SSE covers streaming without introducing a more complex baseline transport.

### Multiple bindings

A2A is not permanently tied to JSON-RPC. The spec explicitly allows custom bindings as long as they preserve protocol semantics and are declared clearly in the Agent Card. That creates a path for ecosystems that prefer gRPC or another transport while still staying within the A2A conceptual model.

## Streaming and Asynchronous Work

A2A is built for more than one-shot interactions.

### Streaming

`SendStreamingMessage` and `SubscribeToTask` support real-time updates. The spec says a task stream can include:

- the initial `Task` object,
- `TaskStatusUpdateEvent` entries,
- `TaskArtifactUpdateEvent` entries,
- stream completion when the task reaches a terminal state.

### Push notifications

For asynchronous delivery, A2A includes push notification configuration methods and a `PushNotificationConfig` model. The spec also requires normal HTTP authentication patterns for notification delivery and states that clients should process notifications idempotently because duplicates can occur.

This matters operationally. Many agent tasks are slow, externally dependent, or human-in-the-loop. A2A treats that as a normal case, not an edge case.

## Security Model

A2A is designed with enterprise operation in mind. The specification includes:

- authentication and authorization sections,
- declared security schemes in the Agent Card,
- support for scoped authorization,
- transport security requirements,
- guidance for push notification security,
- guidance for signed Agent Cards.

The current spec states that production systems must use encrypted communication and recommends modern TLS configurations. It also requires authorization checks on every A2A request and insists that responses be scoped to the caller’s authorized access boundaries.

That is a strong signal that A2A is intended for real organizations, not only as a developer demo protocol.

## Versioning and Compatibility

A2A versioning is explicit. The spec says the protocol version in use is identified by the `Major.Minor` form of the specification version, such as `1.0`. Patch releases do not affect wire compatibility.

The v1.0 spec also documents migration changes from prior versions, including:

- removal of the old `kind` discriminator pattern in favor of wrapper-object style type discrimination,
- relocation of extended Agent Card support into the `capabilities` object.

This is important for implementers. A2A is maturing, but it is still young enough that clients and servers need to pay attention to version negotiation and migration notes.

## Strengths

### Clear separation between agents and tools

A2A’s strongest conceptual contribution is its insistence that agents are not just tools. That distinction makes the protocol better suited for delegation, negotiation, stateful collaboration, and long-running work.

### Good discovery model

The Agent Card is a practical and reusable discovery mechanism. It makes it easier to build ecosystems where agents can be found and understood without out-of-band integration documents.

### Strong task abstraction

Tasks, task states, streaming updates, and push notifications form a coherent execution model. This is one of A2A’s biggest practical advantages.

### Enterprise-minded design

Security, auth, transport guidance, and authorization scoping are first-class concerns in the spec.

### Extensible architecture

A2A supports extensions and multiple bindings, which gives it room to evolve without forcing a single runtime model.

## Limitations and Risks

### Young standard

Even at `1.0.0`, A2A is still an emerging protocol. Early implementers should expect some ecosystem churn, uneven SDK maturity, and continued clarification around edge cases.

### Discovery is descriptive, not magical

The Agent Card tells clients what an agent claims to do. It does not guarantee semantic quality, reliability, or interoperability depth beyond the declared contract.

### Operational burden remains

A2A solves protocol-level interoperability, but not everything around it. Teams still need:

- observability,
- trust and identity management,
- SLAs,
- retry policy,
- abuse controls,
- governance over agent behavior.

### Higher complexity than simple tool calling

For narrow, deterministic integrations, A2A may be heavier than necessary. If the remote capability is just a stateless function, MCP or a direct API may be a better fit.

## A2A vs MCP

The official A2A materials are clear that A2A and MCP are complementary, not competing.

### MCP

MCP is for agent-to-tool communication. It standardizes how an agent connects to APIs, data sources, tools, and resources.

### A2A

A2A is for agent-to-agent communication. It standardizes how autonomous agents discover each other, exchange context, manage tasks, and collaborate as peers.

### Practical rule of thumb

Use MCP when the remote thing behaves like a tool.

Use A2A when the remote thing behaves like an agent:

- stateful,
- multi-turn,
- delegated,
- potentially long-running,
- capable of asking for clarification or additional authentication.

In real systems, both often belong together: an agent may use MCP internally for tools while using A2A externally to collaborate with other agents.

## A2A vs ACP

Official A2A docs now state that IBM ACP has been incorporated into A2A.

That means the current relationship is not really “A2A or ACP” as two equal future standards. Instead:

- ACP remains useful as background and migration history.
- A2A is the active standard to evaluate now.
- Some ACP ideas, such as agent discovery, structured messages, and resumable work, clearly carry forward into A2A’s design direction.

## Practical Adoption Guidance

### A good fit for A2A

A2A is a strong fit when:

- you need agents from different teams or vendors to interoperate,
- tasks are multi-step or long-running,
- the remote system is genuinely agentic rather than just a function endpoint,
- you need discovery, capability declaration, and structured lifecycle handling,
- you want a standard that is currently active and gaining ecosystem support.

### A weaker fit for A2A

A2A is a weaker fit when:

- the interaction is simple and stateless,
- the remote service is really just a tool,
- the overhead of task lifecycle and discovery is not justified,
- you need maximum simplicity over agentic flexibility.

### Sensible architecture pattern

A practical default architecture is:

- MCP inside an agent for tools and resources,
- A2A between agents,
- ordinary application orchestration around both.

That matches the official framing and keeps protocol responsibilities clean.

## Conclusion

A2A is the most important current open protocol for agent-to-agent interoperability. Its key ideas are strong: discoverable agents, explicit capabilities, structured messages and artifacts, durable task lifecycles, streaming updates, async notifications, and security-conscious operations.

Its biggest advantage is conceptual clarity. It does not try to turn agents into tools. Instead, it gives autonomous systems a shared contract for collaboration. That makes it more appropriate for real multi-agent systems than plain RPC or tool-calling abstractions alone.

The main caution is maturity. A2A is now released at `1.0.0`, but it remains early enough that implementers should expect ecosystem evolution and should track specification and SDK changes closely. Even so, for new work in agent interoperability, A2A is currently the standard with the clearest forward momentum.

## Sources

- [A2A documentation home](https://a2a-protocol.org/dev/)
- [A2A official specification overview](https://a2a-protocol.org/dev/specification/)
- [A2A GitHub repository](https://github.com/a2aproject/A2A)
- [A2A and MCP guide](https://a2a-protocol.org/latest/topics/a2a-and-mcp/)
- [What is A2A?](https://a2a-protocol.org/dev/topics/what-is-a2a/)
