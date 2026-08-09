import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { AuthProvider, useAuth } from "./auth/AuthProvider";
import { LoginScreen } from "./auth/LoginScreen";
import { PlannerPage } from "./components/PlannerPage";
import { cs } from "./i18n/cs";

function Gate() {
  const { state } = useAuth();
  if (state === "booting") {
    return (
      <div style={{ display: "grid", placeItems: "center", height: "100%" }}>{cs.loading}</div>
    );
  }
  if (state === "anonymous") {
    return <LoginScreen />;
  }
  return <PlannerPage />;
}

export function App() {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: { refetchOnWindowFocus: true, retry: 1 },
        },
      }),
  );

  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Gate />
      </AuthProvider>
    </QueryClientProvider>
  );
}
