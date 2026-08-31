import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function magiExtension(pi: ExtensionAPI) {
  pi.setLabel("MAGI");

  pi.registerCommand("magi", {
    description:
      "Run an in-session, read-only MAGI deliberation on a bounded decision.",
    handler: async (args, ctx) => {
      const decision = args.trim();

      const message = [
        "Run a MAGI deliberation on a single bounded decision.",
        "",
        "<magi-decision>",
        decision,
        "</magi-decision>",
        "",
        "Do this now:",
        "",
        "1. Invoke agent `magi-core` exactly once, with the stable task name `MAGI-CORE`. Do not deliberate yourself and do not add your own opinion.",
        "2. Establish the exact decision. If <magi-decision> is non-empty, treat its contents verbatim as the decision to deliberate. If it is empty, identify the decision currently under discussion in this conversation; ask me to state it only when no exact decision can be established from context.",
        "3. Give MAGI-CORE a bounded input built from the relevant conversation context, including where known: the desired outcome and exact decision; observed evidence and its source references; constraints, non-goals, assumptions, and material unknowns; candidate approaches already raised; and relevant prior decisions or reconsideration triggers.",
        "4. Do not pass the unfiltered conversation transcript. MAGI-CORE owns construction of the formal common dossier.",
        "5. MAGI is read-only and advisory. When MAGI-CORE returns, relay its decision dossier to me; whether to act on it remains my choice.",
      ].join("\n");

      // Idle: start the turn now. Streaming: queue behind the active turn
      // (never steer/interrupt it). `followUp` from an idle session never fires.
      if (ctx.isIdle()) pi.sendUserMessage(message);
      else pi.sendUserMessage(message, { deliverAs: "followUp" });
    },
  });
}
