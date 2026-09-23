// A 1-hour health-score sparkline (one point a minute). One series, so no legend — the tile's
// title names it; a faint rule at 90 marks "meeting SLOs"; hover gives the exact value.
import { Line, LineChart, ReferenceLine, ResponsiveContainer, Tooltip, YAxis } from "recharts";

export function Sparkline({ values, label }: { values: number[]; label: string }) {
  if (!values.length) return <div className="h-10 text-[11px] text-ink-3">no history</div>;
  const n = values.length;
  const data = values.map((v, i) => ({ v, ago: n - 1 - i }));
  return (
    <div className="h-10 w-full" role="img" aria-label={`${label}: last hour, from ${values[0]} to ${values[n - 1]}`}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={data} margin={{ top: 4, right: 2, bottom: 2, left: 2 }}>
          <YAxis domain={[0, 100]} hide />
          <ReferenceLine y={90} stroke="#383835" strokeDasharray="3 3" />
          <Tooltip
            cursor={{ stroke: "#93928a", strokeWidth: 1 }}
            contentStyle={{ background: "#2a2a27", border: "1px solid #383835", borderRadius: 6, fontSize: 12, padding: "4px 8px" }}
            labelStyle={{ display: "none" }}
            itemStyle={{ color: "#ffffff" }}
            formatter={(v, _n, item) => [`${Number(v).toFixed(1)}`, `${(item?.payload as { ago: number })?.ago ?? 0} min ago`]}
          />
          <Line type="monotone" dataKey="v" stroke="#3987e5" strokeWidth={2} dot={false} isAnimationActive={false} activeDot={{ r: 4 }} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
