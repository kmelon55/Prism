import { useId } from "react";

/** Obsidian prism, a silver cut, and a narrow band of dispersed light. */
export function PrismMark({ className = "" }: { className?: string }) {
  const id = useId();
  return (
    <svg className={`prism-logo ${className}`} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <defs>
        <linearGradient id={`${id}-body`} x1="4" y1="2" x2="27" y2="32" gradientUnits="userSpaceOnUse">
          <stop stopColor="#303236" /><stop offset=".48" stopColor="#111214" /><stop offset="1" stopColor="#050506" />
        </linearGradient>
        <linearGradient id={`${id}-cut`} x1="8" y1="8" x2="25" y2="26" gradientUnits="userSpaceOnUse">
          <stop stopColor="#FFFFFF" /><stop offset=".36" stopColor="#D6DBDE" /><stop offset=".65" stopColor="#6A6E76" /><stop offset="1" stopColor="#C5CBCF" />
        </linearGradient>
        <linearGradient id={`${id}-spectrum`} x1="21" y1="14" x2="25" y2="25" gradientUnits="userSpaceOnUse">
          <stop stopColor="#F1A1A0" /><stop offset=".18" stopColor="#EBC58F" /><stop offset=".34" stopColor="#E5DEA0" />
          <stop offset=".5" stopColor="#A1D6B7" /><stop offset=".67" stopColor="#8FCBE9" /><stop offset=".83" stopColor="#A2B2E8" /><stop offset="1" stopColor="#C2A7DD" />
        </linearGradient>
      </defs>
      <rect x=".5" y=".5" width="31" height="31" rx="8.5" fill={`url(#${id}-body)`} stroke="#FFFFFF" strokeOpacity=".18" />
      <path d="M16 5.7 27 25H5L16 5.7Z" fill="#08090B" stroke={`url(#${id}-cut)`} strokeWidth="1.15" strokeLinejoin="round" />
      <path d="m16 5.7 3.2 17.4L27 25 16 5.7Z" fill={`url(#${id}-spectrum)`} fillOpacity=".85" />
      <path d="m16 5.7 3.2 17.4L5 25 16 5.7Z" fill={`url(#${id}-cut)`} fillOpacity=".12" />
      <path d="m3.5 18.4 9.5-2.7 6.2 7.4" stroke="#FFFFFF" strokeOpacity=".88" strokeWidth=".8" strokeLinecap="round" strokeLinejoin="round" />
      <path d="m19.2 23.1 7.8 1.9" stroke="#FFFFFF" strokeOpacity=".42" strokeWidth=".65" />
    </svg>
  );
}
