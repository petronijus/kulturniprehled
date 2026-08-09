/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_KP_GOOGLE_CLIENT_ID?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

declare module "*.module.css" {
  const classes: Record<string, string>;
  export default classes;
}
