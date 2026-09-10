import type { ReactNode } from "react";
import { motion, useIsPresent } from "motion/react";

export function AiConversationTransition({ children, onReady }: { children: ReactNode; onReady(): void }) {
  const present = useIsPresent();
  return <motion.div className="ai-conversation" inert={!present} aria-hidden={!present || undefined}
    initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
    exit={{ opacity: 0, y: -4 }}
    transition={{ duration: present ? 0.24 : 0.1, delay: present ? 0.06 : 0, ease: [0.22, 1, 0.36, 1] }}
    onAnimationComplete={() => { if (present) onReady(); }}>
    {children}
  </motion.div>;
}
