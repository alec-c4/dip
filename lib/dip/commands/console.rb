# frozen_string_literal: true

require_relative "../command"

module Dip
  module Commands
    module Console
      # Figure out which shell dialect to generate integration code for.
      #
      # An explicit value (from `--shell`) always wins. Otherwise we guess from
      # the `$SHELL` environment variable and fall back to the POSIX flavour
      # (bash/zsh) which was the only supported one historically.
      def self.detect_shell(explicit = nil)
        name = (explicit || File.basename(ENV["SHELL"].to_s)).to_s.downcase
        name.include?("fish") ? :fish : :posix
      end

      class Start < Dip::Command
        def initialize(shell: nil)
          @shell = Console.detect_shell(shell)
        end

        def execute
          puts fish? ? fish_script : posix_script
        end

        private

        def fish?
          @shell == :fish
        end

        def inject_command
          "#{Dip.bin_path} console inject --shell #{@shell}"
        end

        def posix_script
          <<-SH.gsub(/^ {12}/, "")
            export DIP_SHELL=1
            export DIP_EARLY_ENVS=#{ENV.keys.join(",")}
            export DIP_PROMPT_TEXT="ⅆ"

            function dip_clear() {
              # just stub, will be redefined after injecting aliases
              true
            }

            function dip_inject() {
              eval "$(#{inject_command})"
            }

            function dip_reload() {
              dip_clear
              dip_inject
            }

            # Inspired by RVM
            function __zsh_like_cd() {
              \\typeset __zsh_like_cd_hook
              if
                builtin "$@"
              then
                for __zsh_like_cd_hook in chpwd "${chpwd_functions[@]}"
                do
                  if \\typeset -f "$__zsh_like_cd_hook" >/dev/null 2>&1
                  then "$__zsh_like_cd_hook" || break # finish on first failed hook
                  fi
                done
                true
              else
                return $?
              fi
            }

            [[ -n "${ZSH_VERSION:-}" ]] ||
            {
              function cd()    { __zsh_like_cd cd    "$@" ; }
              function popd()  { __zsh_like_cd popd  "$@" ; }
              function pushd() { __zsh_like_cd pushd "$@" ; }
            }

            export -a chpwd_functions
            [[ " ${chpwd_functions[*]} " == *" dip_reload "* ]] || chpwd_functions+=(dip_reload)

            if [[ "$ZSH_THEME" = "agnoster" ]]; then
              eval "`declare -f prompt_end | sed '1s/.*/_&/'`"

              function prompt_end() {
                if [[ -n $DIP_PROMPT_TEXT ]]; then
                  prompt_segment magenta white "$DIP_PROMPT_TEXT"
                fi

                _prompt_end
              }
            fi

            dip_reload
          SH
        end

        def fish_script
          <<-FISH.gsub(/^ {12}/, "")
            set -gx DIP_SHELL 1
            set -gx DIP_EARLY_ENVS "#{ENV.keys.join(",")}"
            set -gx DIP_PROMPT_TEXT "ⅆ"

            function dip_clear
              # just stub, will be redefined after injecting aliases
              true
            end

            function dip_inject
              #{inject_command} | source
            end

            function dip_reload
              dip_clear
              dip_inject
            end

            # Renew aliases whenever the working directory changes.
            function __dip_chpwd --on-variable PWD
              dip_reload
            end

            dip_reload
          FISH
        end
      end

      class Inject < Dip::Command
        attr_reader :out, :aliases

        def initialize(shell: nil)
          @shell = Console.detect_shell(shell)
          @aliases = []
          @out = []
        end

        def execute
          if Dip.config.exist?
            add_aliases(*Dip.config.interaction.keys) if Dip.config.interaction
            add_aliases("compose", "up", "stop", "down", "provision", "build")
          end

          clear_aliases

          puts out.join("\n\n")
        end

        private

        def fish?
          @shell == :fish
        end

        def add_aliases(*names)
          names.each do |name|
            aliases << name
            out << if fish?
              "function #{name}; #{Dip.bin_path} #{name} $argv; end"
            else
              "function #{name}() { #{Dip.bin_path} #{name} $@; }"
            end
          end
        end

        def clear_aliases
          out << if fish?
            body = aliases.any? ? "functions -e #{aliases.join(" ")}" : "true"
            "function dip_clear; #{body}; end"
          else
            "function dip_clear() { \n" \
              "#{aliases.any? ? aliases.map { |a| "  unset -f #{a}" }.join("\n") : "true"} " \
              "\n}"
          end
        end
      end
    end
  end
end
