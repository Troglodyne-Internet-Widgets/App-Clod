If the change needs a CPAN module that is not installed, install it with
`clod-cpm Module::Name`. It goes into a lib of your own, which every later
command finds. Then add it to the prerequisites of the distribution, in the way
that this repository declares them.
