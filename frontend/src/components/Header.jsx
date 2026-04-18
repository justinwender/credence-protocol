export default function Header({ account, onConnect, onDisconnect, isConnecting, onReset }) {
  const truncate = (addr) => addr ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : '';

  return (
    <header className="border-b border-border px-6 py-4 flex items-center justify-between">
      <button
        onClick={onReset}
        className="flex items-center gap-3 hover:opacity-80 transition-opacity cursor-pointer"
        title="Return to home"
      >
        <div className="w-8 h-8 rounded bg-accent flex items-center justify-center text-bg-primary font-bold text-sm">
          C
        </div>
        <div className="text-left">
          <h1 className="text-lg font-semibold text-text-primary tracking-tight">
            Credence Protocol
          </h1>
          <p className="text-xs text-text-muted">
            Onchain Credit Scoring & Undercollateralized Lending
          </p>
        </div>
      </button>

      <div className="flex items-center gap-3">
        {account ? (
          <>
            <span className="text-xs font-mono text-text-secondary bg-bg-card px-3 py-1.5 rounded border border-border">
              {truncate(account)}
            </span>
            <button
              onClick={onDisconnect}
              className="text-xs text-text-muted hover:text-text-secondary transition-colors"
            >
              Disconnect
            </button>
          </>
        ) : (
          <button
            onClick={onConnect}
            disabled={isConnecting}
            className="px-4 py-2 text-sm font-medium rounded bg-accent text-bg-primary hover:bg-accent-bright transition-colors disabled:opacity-50"
          >
            {isConnecting ? 'Connecting...' : 'Connect Wallet'}
          </button>
        )}
      </div>
    </header>
  );
}
