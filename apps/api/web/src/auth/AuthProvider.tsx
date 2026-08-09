import type { ReactNode } from "react";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { loginWithGoogle, logout, setSessionLostHandler } from "../api/client";
import { refreshSession } from "./refresh";
import { hasSession } from "./tokenStore";

type AuthState = "booting" | "anonymous" | "authenticated";

interface AuthContextValue {
  state: AuthState;
  signIn: (idToken: string) => Promise<void>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>("booting");

  useEffect(() => {
    setSessionLostHandler(() => setState("anonymous"));
    if (!hasSession()) {
      setState("anonymous");
      return;
    }
    void refreshSession().then((ok) => setState(ok ? "authenticated" : "anonymous"));
  }, []);

  const signIn = useCallback(async (idToken: string) => {
    await loginWithGoogle(idToken);
    setState("authenticated");
  }, []);

  const signOut = useCallback(async () => {
    await logout();
    setState("anonymous");
  }, []);

  const value = useMemo(() => ({ state, signIn, signOut }), [state, signIn, signOut]);
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const value = useContext(AuthContext);
  if (value === null) {
    throw new Error("useAuth outside AuthProvider");
  }
  return value;
}
