# Storage Growth Forecast

A single-page tool that forecasts storage growth from usage history.

- Paste or upload a CSV with a date column and a used-space column.
- Set usable capacity, unit (GB/TB/PB), forecast horizon in months, and an alert threshold.
- Fits linear and compounding growth trends and shows when each reaches the threshold and full capacity.

## Use

Open `index.html` in a browser. No build step or dependencies (fonts load from Google Fonts). All calculations run locally in the page.

## CSV format

```
date,used_tb
2025-04-01,38.6
2025-05-01,39.4
```

A header row is optional. At least 3 rows spanning 3 weeks or more are required.
