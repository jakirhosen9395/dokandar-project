"use client";

// Root error boundary — must render its own <html>/<body> (it replaces the root layout on a crash).
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "system-ui, sans-serif", display: "flex", minHeight: "100vh", alignItems: "center", justifyContent: "center", textAlign: "center", padding: "1rem", margin: 0 }}>
        <div>
          <h1 style={{ fontSize: "1.5rem", fontWeight: 700 }}>Application error</h1>
          <p style={{ marginTop: "0.5rem", color: "#666" }}>A critical error occurred.{error.digest ? ` (ref: ${error.digest})` : ""}</p>
          <button onClick={reset} style={{ marginTop: "1.5rem", padding: "0.5rem 1rem", border: "1px solid #ccc", borderRadius: "0.375rem", cursor: "pointer" }}>Reload</button>
        </div>
      </body>
    </html>
  );
}
