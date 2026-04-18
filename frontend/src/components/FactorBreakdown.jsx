export default function FactorBreakdown({ factors = [] }) {
  return (
    <div className="rounded-lg border border-border bg-bg-card overflow-hidden">
      <div className="px-4 py-3 border-b border-border">
        <h3 className="text-text-primary text-sm font-semibold tracking-wide uppercase">
          Score Factors
        </h3>
      </div>

      <table className="w-full text-sm">
        <thead>
          <tr className="text-text-muted text-xs uppercase tracking-wider">
            <th className="text-left px-4 py-2 font-medium">Factor</th>
            <th className="text-left px-4 py-2 font-medium">Value</th>
            <th className="text-right px-4 py-2 font-medium">Impact</th>
          </tr>
        </thead>
        <tbody>
          {factors.map((f, i) => (
            <tr
              key={f.feature}
              className={i % 2 === 0 ? 'bg-bg-card' : 'bg-bg-primary/40'}
            >
              <td className="px-4 py-2 text-text-secondary">
                {f.display_name}
              </td>
              <td className="px-4 py-2 font-mono text-text-muted text-xs">
                {f.bin}
              </td>
              <td className="px-4 py-2 text-right font-mono">
                {f.is_reference ? (
                  <span className="text-text-muted">(baseline)</span>
                ) : (
                  <span
                    className={
                      f.coefficient < 0 ? 'text-danger' : 'text-accent'
                    }
                  >
                    {f.coefficient > 0 ? '+' : ''}
                    {f.coefficient.toFixed(3)}
                  </span>
                )}
              </td>
            </tr>
          ))}

          {factors.length === 0 && (
            <tr>
              <td
                colSpan={3}
                className="px-4 py-6 text-center text-text-muted"
              >
                No factor data available
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
