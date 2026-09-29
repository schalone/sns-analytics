"""PNG charts for the brief (matplotlib, headless). Pure functions take plain lists so they are testable."""
import io, datetime as dt

def _fig():
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt

def line_chart(dates, series, title, ylabel_left, right=None):
    """dates: [date]; series: {label: [values]} on the left axis; right: optional (label, values) on a right axis."""
    plt = _fig(); fig, ax = plt.subplots(figsize=(9, 3.6), dpi=130)
    for label, vals in series.items(): ax.plot(dates, vals, marker="o", ms=3, lw=1.6, label=label)
    ax.set_ylabel(ylabel_left); ax.grid(alpha=.25); ax.set_title(title, loc="left", fontsize=11, fontweight="bold")
    if right:
        ax2 = ax.twinx(); ax2.plot(dates, right[1], color="#c44", lw=1.6, ls="--", marker="s", ms=3, label=right[0]); ax2.set_ylabel(right[0])
        h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels(); ax.legend(h1 + h2, l1 + l2, loc="upper left", fontsize=8, frameon=False)
    else: ax.legend(loc="upper left", fontsize=8, frameon=False)
    fig.autofmt_xdate(); fig.tight_layout(); buf = io.BytesIO(); fig.savefig(buf, format="png"); plt.close(fig); return buf.getvalue()
