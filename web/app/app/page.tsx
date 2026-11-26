import type { Metadata } from "next";
import { Dashboard } from "@/components/dashboard/Dashboard";

export const metadata: Metadata = {
  title: "Dashboard",
  description: "Your Macs in Silicon Mode: live status, agents, tail logs, questions and when your agents run.",
  robots: { index: false, follow: false },
};

export default function AppPage() {
  return <Dashboard />;
}
