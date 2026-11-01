# experiments

| Folder | Experiment |
|---|---|
| [`join-node/`](join-node/) | one extra node joins a running network, on the same machine or on another one |
| [`measure/`](measure/) | join time, transaction latency and block propagation under added delay and loss; checkpoints on a growing chain |
| [`load/`](load/) | keep the blocks of the chain full of transactions |
| [`saturation/`](saturation/) | how many sensor readings per second the chain takes, and the waiting time near that limit (batch size and rate sweep) |
| [`outsider/`](outsider/) | a rogue node with another genesis and magic dials a pool: who rejects it, how fast, and does the real chain notice |

## Results

`measure/`, `saturation/` and `outsider/` write their runs to `results/<run>/`. Only the small summary files (CSV, TXT) are in git; the raw node logs of the runs (about 11 GB) are not. The run folders and what they hold are listed at the end of the report: [`../docs/measurement-report.html`](../docs/measurement-report.html) (open it in a browser; it explains why each measurement was taken, the numbers, and how far to trust them).

