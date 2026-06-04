# KubeQuest

The clean cycle

  1. commit    your code change (welcome.blade.php, etc.)
  2. push      → your code is now on origin/develop
  3. deploy    builds from origin/develop, then pushes its own
               "chore(deploy): tag -> vX" commit to origin
  4. pull      bring that tag-bump commit back local

  Then the next change is just the same cycle again:

  5. commit
  6. push
  7. deploy
  8. pull
