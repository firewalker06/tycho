# Agent Communication Protocol (ACP) Research

## Executive Summary

Agent Communication Protocol (ACP) is an open, HTTP-native protocol for interoperability between AI agents, applications, and humans. It was introduced by IBM Research and the BeeAI ecosystem to solve a specific problem: agents are often built in isolated frameworks and exposed through incompatible APIs, which makes multi-agent composition expensive and brittle.

ACP standardizes agent communication through a RESTful interface, structured multimodal messages, agent discovery, and support for synchronous, asynchronous, and streaming execution modes. Its design goal is not to define how agents think internally, but how independent agents expose capabilities and exchange work.

The most important current status point is that ACP is no longer evolving as a standalone protocol. Official ACP sources now state that ACP has been merged into A2A under the Linux Foundation, and ACP’s original repository was archived in August 2025. That makes ACP important to understand historically and architecturally, but risky to adopt as a new greenfield standard without first checking the A2A migration path.

## Why ACP Exists

ACP was created to address fragmentation in the agent ecosystem:

- Different teams use different frameworks, languages, and runtimes.
- Agents are often wrapped as custom services with bespoke request and response formats.
- Multi-agent systems frequently require one-off integrations that do not scale.
- Cross-team or cross-organization collaboration becomes difficult when there is no shared protocol.

ACP’s response is to treat an agent as a network-accessible service with a standard interface. In practice, that means a client can discover an agent, inspect its metadata, send it structured input, track the run lifecycle, and receive output in a predictable format without caring about the agent’s internal implementation.

## Core Design Principles

Official ACP documentation emphasizes a few central design choices:

### 1. HTTP-native, RESTful communication

ACP uses standard HTTP patterns instead of a custom transport. This keeps integration simple and production-friendly. A basic ACP server can be queried with ordinary tools such as `curl`, Postman, or any HTTP client.

### 2. SDK-optional interoperability

ACP provides SDKs, but the protocol is meant to remain usable without them. The protocol contract lives in its API design and data models rather than in a required library.

### 3. Multimodal messages

ACP messages are not limited to plain text. A message is composed of ordered parts, each with a MIME type and either inline content or a content URL. This allows the protocol to carry text, JSON, images, files, and other artifacts in a uniform way.

### 4. Async-first execution

ACP is designed for long-running agent work. It supports:

- synchronous runs for direct request/response usage,
- asynchronous runs for queued or long-running jobs,
- streaming runs for incremental events over Server-Sent Events (SSE).

### 5. Discovery and composability

ACP includes agent manifests and discovery mechanisms so systems can find agents and understand what they do before invoking them.

### 6. Implementation agnosticism

ACP does not dictate the internal architecture of the agent. A LangChain agent, a custom Python service, or another orchestration stack can all be ACP-compatible as long as they expose the protocol correctly.

## ACP Architecture

ACP documentation frames the system around clients, servers, and agents:

- An ACP client is any application, service, or agent that makes protocol-compliant requests.
- An ACP server exposes one or more agents through a REST interface.
- An ACP agent is the unit of capability that actually performs the work.

This supports several deployment models:

- Single-agent deployment: one client talks to one ACP-exposed agent.
- Multi-agent single server: several agents are hosted behind one ACP server.
- Distributed multi-agent systems: an agent can also act as a client and call other agents.

That last pattern is central to ACP’s value proposition. ACP is intended to let specialized agents collaborate as peers across process, runtime, or organizational boundaries.

## Core Protocol Concepts

### Agent Manifest

The agent manifest describes an agent’s identity and capabilities. It is used for discovery and composition. Typical metadata includes:

- name,
- description,
- capabilities,
- supported content types,
- operational metadata.

The goal is to let clients understand what an agent can do without exposing its internals.

### Message and Message Parts

A `Message` is the main communication unit. Each message has:

- a `role`, such as `user`, `agent`, or `agent/{name}`,
- an ordered list of `parts`.

Each `MessagePart` includes:

- `content_type` as a MIME type,
- inline `content` or `content_url`,
- optional `content_encoding`,
- optional `name` for artifact-like outputs,
- optional metadata.

This makes ACP more structured than a plain chat payload. It is designed to support real artifacts and non-text communication patterns, not just text prompts and text responses.

### Runs

A run represents one invocation of an agent. ACP defines a lifecycle around that run, including status transitions such as:

- `created`,
- `in-progress`,
- `awaiting`,
- `completed`,
- `failed`.

The `awaiting` state is particularly notable because it allows an agent to pause and wait for external input before continuing. That is useful for human-in-the-loop or multi-step workflows.

### Sessions

ACP supports both stateless and stateful interaction patterns. Sessions let agents maintain conversation or execution history across multiple runs. Official docs also describe distributed sessions, where session state can be referenced and shared across systems through URLs and resource endpoints.

### Discovery

ACP supports several discovery patterns:

- querying a running server directly,
- public manifest files,
- registry-based discovery,
- embedded or offline metadata.

Offline discovery is a meaningful differentiator because it helps in environments where agents are packaged, scaled to zero, or not continuously online.

## Main API Shape

The official docs highlight a compact API surface:

- `GET /agents`: discover available agents on a server.
- `POST /runs`: create a new run for an agent.
- `GET /runs/{run_id}`: inspect run state and output.
- `POST /runs/{run_id}`: resume a run that is waiting for additional input.
- `POST /runs/{run_id}/cancel`: cancel an in-progress run.
- `GET /sessions/{session_id}`: inspect session descriptors in session-oriented setups.

This API shape reflects ACP’s core opinion: an agent should look like a service that can be discovered, invoked, resumed, and observed through standard HTTP semantics.

## Security and Production Characteristics

ACP is positioned as production-friendly rather than experimental-only. Official material emphasizes:

- TLS for transport security,
- support for common HTTP auth patterns such as bearer tokens and JWTs,
- reverse-proxy compatibility,
- stateless protocol semantics where possible,
- optional stateful session handling where needed.

This is an important architectural choice. ACP does not invent a special transport security model; it leans on familiar web infrastructure and operations practices.

## Strengths

ACP has several clear advantages as a protocol design:

### Simplicity

Because ACP is RESTful and HTTP-native, it is relatively easy to understand and integrate compared with protocols that require more specialized transports or runtime assumptions.

### Clear unit of work

The run lifecycle gives ACP a strong execution model for agent tasks, especially long-running and resumable work.

### Good support for real outputs

The message-part model handles multimodal and artifact-based communication more cleanly than plain text chat abstractions.

### Framework independence

ACP’s value increases in heterogeneous environments where teams want to expose agents from different stacks without rewriting everything into a single framework.

### Useful discovery model

Discovery and manifests make ACP more reusable than opaque “send a POST to this custom endpoint” integrations.

## Limitations and Risks

ACP also has meaningful constraints:

### Governance and momentum risk

The most serious current risk is ecosystem direction. ACP’s official site and IBM materials now state that ACP is part of A2A under the Linux Foundation, and the original `i-am-bee/acp` repository is archived. That means ACP should be evaluated as a transitional protocol rather than a standalone strategic bet.

### Limited independent ecosystem depth

ACP had strong backing from IBM Research and BeeAI, but it did not become the sole industry-wide standard before consolidation into A2A. Organizations looking for broad third-party momentum will need to evaluate the A2A ecosystem rather than ACP in isolation.

### Not an orchestration framework

ACP standardizes communication, not workflow management, deployment, scheduling, or policy coordination. It helps agents interoperate, but teams still need orchestration, monitoring, governance, and runtime controls outside the protocol itself.

### Operational complexity remains

Standardizing wire format reduces integration cost, but does not eliminate deeper problems such as trust boundaries, authorization, version compatibility, or business-level coordination between independently owned agents.

## ACP vs MCP

ACP and MCP solve different layers of the stack.

### MCP

Model Context Protocol (MCP) is primarily about connecting a model or agent to tools, resources, and context. Its center of gravity is tool invocation and context provision for a single agent or model-driven application.

### ACP

Agent Communication Protocol is about communication between independently exposed agents. Its center of gravity is peer-to-peer or service-to-service interoperability between agentic systems.

### Practical distinction

The simplest way to frame the difference is:

- MCP: one agent or model talking to many tools and data sources.
- ACP: many agents talking to each other through a shared service contract.

These are complementary rather than mutually exclusive. A system could use MCP inside an individual agent and ACP between agents.

## ACP vs A2A

ACP and A2A address very similar problems, which is exactly why ACP was folded into A2A.

From the current official ACP messaging:

- ACP is now part of A2A under the Linux Foundation.
- ACP development has effectively transitioned into the broader A2A effort.
- Migration guidance is the right next step for ACP users.

From an architecture perspective, ACP contributed practical ideas around:

- HTTP-native agent exposure,
- run lifecycle management,
- multimodal structured messages,
- discovery and session handling.

For new adoption, the relevant question is usually no longer “Should we adopt ACP?” but “Which ACP ideas matter to us, and how do they map onto A2A?”

## Practical Adoption Guidance

### When ACP is still worth studying

ACP is still worth researching if you want:

- a concrete example of an HTTP-based agent interoperability protocol,
- design ideas for internal multi-agent APIs,
- a useful comparison point against MCP and A2A,
- to understand BeeAI-era protocol patterns.

### When ACP is a poor greenfield choice

ACP is a weaker choice for new external-facing standardization if:

- you want the protocol with the strongest current momentum,
- you need an actively evolving ecosystem standard,
- you are starting from scratch and can choose A2A directly.

### When ACP concepts are still useful internally

Even if you never adopt ACP as-is, its design is still valuable for internal platform work. The following concepts remain broadly useful:

- explicit agent manifests,
- a run abstraction with lifecycle states,
- resumable execution,
- multimodal message parts,
- HTTP-based discovery and invocation.

## Conclusion

ACP is a strong and practical attempt to standardize agent-to-agent interoperability using familiar web primitives. Its design is clean: discover agents, invoke runs, exchange structured multimodal messages, and manage stateful or long-running work through standard HTTP patterns.

Its main weakness today is not technical structure but strategic status. ACP is best understood as an influential protocol that has already transitioned into A2A rather than as a long-term standalone destination. For research, architecture, and internal platform design, ACP remains highly relevant. For new platform commitments, it should usually be evaluated through the lens of A2A migration and ecosystem direction.

## Sources

- [IBM Research](https://research.ibm.com/projects/agent-communication-protocol)
- [ACP documentation home](https://agentcommunicationprotocol.dev/)
- [ACP architecture](https://agentcommunicationprotocol.dev/core-concepts/architecture)
- [ACP message structure](https://agentcommunicationprotocol.dev/core-concepts/message-structure)
- [ACP agent discovery](https://agentcommunicationprotocol.dev/core-concepts/agent-discovery)
- [ACP run lifecycle](https://agentcommunicationprotocol.dev/core-concepts/agent-run-lifecycle)
- [ACP production-grade guidance](https://agentcommunicationprotocol.dev/core-concepts/production-grade)
- [IBM explainer](https://www.ibm.com/think/topics/agent-communication-protocol)
- [ACP GitHub repository](https://github.com/i-am-bee/acp)
- [ACP to A2A announcement](https://github.com/orgs/i-am-bee/discussions/5)
