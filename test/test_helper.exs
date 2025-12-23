ExUnit.start(exclude: [:crash_harness])

# Start the pool
{:ok, _} = TripleStore.Test.DbPool.start_link()
