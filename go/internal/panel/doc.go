// Package panel implements the watch pane used by forward watch.
//
// The implementation mirrors lib/panel.sh's terminal contract: alternate
// screen transitions are paired, frames are built before a single write, a
// timed byte read drives refreshes, and EOF is a clean exit.
package panel
