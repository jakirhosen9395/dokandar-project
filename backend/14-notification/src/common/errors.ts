// The single error-envelope shape + a typed AppError. The HTTP layer's
// setErrorHandler scrubs raw 5xx internals before they reach the client and
// logs the raw cause to the forensic sink.

export interface ErrorEnvelope {
  error: {
    code: string;
    message: string;
    request_id: string;
    details?: unknown;
  };
}

// Build the canonical envelope: { error: { code, message, request_id, details? } }.
// `details` is omitted entirely (not null) when not supplied.
export function buildEnvelope(code: string, message: string, request_id: string, details?: unknown): ErrorEnvelope {
  const error: ErrorEnvelope['error'] = { code, message, request_id };
  if (details !== undefined) error.details = details;
  return { error };
}

// A throwable that carries the HTTP status + the stable machine `code`. The
// `message` is client-safe; never put raw driver/SQL/stack text here.
export class AppError extends Error {
  readonly statusCode: number;
  readonly code: string;
  readonly details?: unknown;
  constructor(statusCode: number, code: string, message: string, details?: unknown) {
    super(message);
    this.name = 'AppError';
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
    Object.setPrototypeOf(this, AppError.prototype);
  }
}
