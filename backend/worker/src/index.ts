// Worker entry point. Keep this module to the default export only: workerd
// treats every named export of the entry module as an entrypoint and fails
// to start if one is not a handler. Logic lives in ./handler.
import { handle, type Env } from './handler';

export default {
  fetch: (request: Request, env: Env) => handle(request, env),
} satisfies ExportedHandler<Env>;
