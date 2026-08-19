# Agent Delegation Glossary

Status: accepted for implementation on 2026-08-19

## Delegation

A relationship state in which a parent owns a task performed by a child. Tycho routes eligible child reports to the parent and may wake the parent.

Tycho enters this state immediately before delivering a parent-to-child prompt, including when the child was previously in Takeover.

A user prompt to the parent does not itself restore Delegation. The parent must consequentially prompt that specific child.

If the child has an open answer-required form, the accepted parent prompt cancels that inquiry before proceeding.

## Takeover

A relationship state in which the user owns the child's task. Tycho does not route child reports to the former parent. Any direct user prompt to a delegated child triggers this state before the prompt is delivered.

The state begins when Tycho accepts the direct prompt, including when the prompt is queued behind an active run.

Takeover ends when Tycho delivers a later parent-to-child prompt, which restores Delegation.

## Parent

The agent that prompts another agent to perform a task under Delegation.

## Child

The agent that receives a delegated prompt. Parent and child describe one relationship; they are not permanent properties of an agent.

## Report

A Tycho-routed update derived from a child's run. A report is distinct from a prompt chosen and addressed by the child.

Tycho's lifecycle coordinator chooses the report recipient from the recorded relationship. A child cannot address a report, prompt an ancestor, or delegate work to an ancestor.

Tycho creates at most one report after each completed child run that remains eligible under its ownership generation. Streaming output is not a report.

## Upward channel

The system-controlled report path from a child to its recorded parent. It is available during Delegation and suppressed during Takeover. It is not a general agent messaging channel.

## Direct user prompt

A prompt whose actor is the user and whose recipient is the child, rather than a response routed through the parent.

## Ownership generation

The version of a relationship's current owner. It advances only when ownership changes between parent and user, not for repeated prompts from the same owner. Tycho stamps accepted runs with the current owner and generation; a run can report only when that stamp remains current and parent-owned at completion.

## Relationship edge

One directed parent-child relationship. Delegation and Takeover belong to this edge, not to an agent or an entire descendant subtree.

## Run-bound capability

A short-lived credential that identifies one agent as the source of agent-originated Tycho operations during one run. It cannot identify the caller as the user, another agent, or the lifecycle coordinator.

## Answer-required form

The pending UI inquiry created by an `input_required` child run. A direct user answer enters Takeover. A later parent-to-child prompt cancels the form and proceeds as new delegated work rather than answering the old inquiry.
