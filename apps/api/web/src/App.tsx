import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { PlannerPage } from "./components/PlannerPage";

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
      <PlannerPage />
    </QueryClientProvider>
  );
}
