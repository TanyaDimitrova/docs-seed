DEFAULT_POSITION = 10000
# https://github.com/sindresorhus/semver-regex/blob/master/index.js
VERSION_REGEXP = /\bv?(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:X|0|[1-9][0-9]*)(?:-[\da-z\-]+(?:\.[\da-z\-]+)*)?(?:\+[\da-z\-]+(?:\.[\da-z\-]+)*)?\b/i;

class TreeNode < Liquid::Drop
    include Comparable
    attr_reader :position, :children, :parent, :tags
    def initialize(segment = '', parent = nil)
        @children = []
        @segment = segment
        @parent = parent
        @tags = []

        meta_file = File.join('./', path, '_meta.yml')
    
        if File.exists?(meta_file)
            meta = YAML.load(File.read(meta_file))
        elsif File.exists?('_config.yml')
          # TODO: Here we get the "libraries" from the config (it might be controls or else)
            new_path = path.sub("/components/", "controls/")
            meta = YAML.load(File.read('_config.yml'))['navigation'];
            meta = Hash[(meta || {}).map { |key, value| [key.gsub(/\*(.*?)/, new_path), value] }][new_path]
        end

        if meta
          puts(meta)
          @title = meta["title"]
          @position = meta["position"]
          @tags = (meta["tags"] || "").split(",")
        end 
    end

    def <=>(other)
        pos = position_to_other(other)
        if pos.nil?
            raise "[prev_next plugin] Comparing the pages #{path} and #{other.path} failed"
        end
        pos
    end

    def position_to_other(other)
        if other.nil?
            return -1
        end

        if position != other.position
            position <=> other.position
        elsif title != other.title
            title <=> other.title
        else
            path <=> other.path
        end
    end

    def position
        @position || DEFAULT_POSITION
    end

    def level
        @parent.level + 1
    end

    def path
        [ @parent.path, @segment ].join('/')
    end

    def title
        @title || @segment
    end

    def url
        non_versioned[0].url
    end

    def page?
        false
    end

    def add_page(page)
        @children << PageNode.new(page, self)
    end

    def segment_eq(segment)
        @segment == segment
    end

    def find_or_create_child(segment)
        child = @children.find { |c| c.segment_eq(segment) }

        if !child
            child = TreeNode.new(segment, self)
            @children << child
        end

        child
    end

    def dirs
        @children.reject { |child| child.page? }
    end

    def sort!
        return if path == '/npm'
        @children.sort!

        dirs.each { |dir| dir.sort! }
    end

    def first_child
        if version_node?
            nil
        else
            @children[0]
        end
    end

    def last_child
        if version_node?
            nil
        else
            @children[-1]
        end
    end


    def siblings
        @parent.children
    end

    def index
        siblings.index(self)
    end

    def prev
        if version_node?
            return nil
        end

        if index == 0
            @parent.prev.last_child unless (@parent.prev.nil?)
        else
            siblings[index - 1].last_child
        end
    end

    def next
        if version_node?
            return nil
        end

        if index == siblings.length - 1
            @parent.next.first_child unless (@parent.next.nil?)
        else
            return nil if level == 1
            siblings[index + 1].first_child
        end
    end

    def version_node?
        @segment =~ VERSION_REGEXP
    end

    def non_versioned
        @children.reject {  |child| child.version_node? }
    end

    def is_in_version_tree?
        version_node? || @parent.is_in_version_tree?
    end

    def section_menu(child, child_menu)
        if child.version_node? # transclude the versioned contents as your own
            my_menu = child_menu
        else
            if level == 1
                items = non_versioned[1..-1]
            else
                items = non_versioned
            end
            my_menu = items.map do |node|
                children = node == child ? child_menu : []
                MenuItem.new(node, children)
            end
        end

        @parent.section_menu(self, my_menu)
    end

    def root
        false
    end

    def bread_crumb(baseurl, so_far = nil, wrappers_build = false)
        if so_far && level > 1
            so_far = " / #{so_far}"
        end
        if version_node?
            @parent.parent.bread_crumb(
                baseurl,
                "<a href='#{baseurl}#{@parent.url}#{@segment}/'>#{@parent.title}</a>#{so_far}"
            )
        else
            if level > 1
                if wrappers_build
                    wrappers_url = url.sub('components', 'wrappers')
                    @parent.bread_crumb(
                        baseurl,
                        "<a href='#{baseurl}#{wrappers_url}'>#{title}</a>#{so_far}",
                        wrappers_build
                    )
                else
                    @parent.bread_crumb(
                        baseurl,
                        "<a href='#{baseurl}#{url}'>#{title}</a>#{so_far}"
                    )
                end
            else
                so_far
            end
        end
    end
end

class RootNode < TreeNode
    def section_menu(child, child_menu)
        child_menu
    end

    def root
        true
    end

    def level
        0
    end

    def path
        ''
    end

    def is_in_version_tree?
        false
    end

    def prev
        nil
    end

    def next
        nil
    end
end

class PageNode < TreeNode
    attr_accessor :page

    def first_child
        self
    end

    def last_child
        self
    end

    def initialize(page, parent)
        @page = page
        @page.data['node'] = self
        @parent = parent
        add_package_info
    end

    def add_package_info
        @page.data['is_index'] = @page.path =~ /^components\/[^\/]+\/index.md/

        match = /^components\/(.*?)\//.match(@page.path)
        @page.data['package'] ||= match[1].capitalize if match and match[1]
        if @parent.tags.include?('component')
            @page.data['component'] ||= @parent.title
        else
            @page.data['subsection'] ||= @parent.title
        end
    end

    def inspect
        @page.path
    end

    def bread_crumb(baseurl, wrappers_build)
        @parent.bread_crumb(baseurl, nil, wrappers_build)
    end

    def section_menu
        @parent.section_menu(self, [])
    end

    def page?
        true
    end

    def set_canonical_data
        if @parent.is_in_version_tree?
            non_versioned_url = @page.url.sub(VERSION_REGEXP, '').gsub("//", "/")

            if $all_pages.find { |page| page.url == non_versioned_url }
                @page.data['needs_canonical'] = true
                @page.data['canonical_url'] = non_versioned_url
            end
        end
    end

    def path
        @page.path
    end

    def url
        @page.url
    end

    def title
        @page.data["title"]
    end

    def segment_eq(segment)
        false
    end

    def position
        @page.data["position"] || DEFAULT_POSITION
    end

    def to_s
        "[#{title}](#{@page.path})"
    end
end

class MenuItem
    attr_reader :children, :url, :page, :tags

    def initialize(node, children)
        @title = node.title || ""
        @url = node.url
        @page = node.page?
        @children = children
        @tags = node.tags || []
    end

    def prefix
        return "" if @page
        return "" if !has_children # collapsed node
        return " <span class='item-expanded'></span> " # expanded node
    end

    def title
        puts "WARN: page #{@url} has no title" if @title == ""
        prefix + " " + @title
    end

    def has_children
        !(@children.empty? || collapsed)
    end

    def collapsed
        @title == 'API'
    end

    def link(base, current)
        "<a #{active(current) ? 'class="active"' : ''} href='#{File.join(base, url)}'>#{title}</a>"
    end

    def wrapper_link(base, current)
        # Only for the special case when we are showing "wrapper" component, alter the actual url
        # so that we could reverse proxy it from nginx to the physical address but keep the "wrappers"
        # part in the url.
        href = File.join(base, url).sub('components', 'wrappers')
        "<a #{active(current) ? 'class="active"' : ''} href='#{href}'>#{title}</a>"
    end

    def active(current)
        (@page && @url == current) || (collapsed && current.start_with?(@url))
    end
end

module Jekyll
    class PrevNext < Generator
        priority :lowest

        def generate(site)
            root = RootNode.new
            $all_pages = site.pages
            site.pages.each do |page|
                tree = root
                segments = page.path.split('/')
                segments.each_with_index do |segment, index|
                    if index == segments.length - 1 && ! page['hidden']
                        tree.add_page(page)
                    else
                        tree = tree.find_or_create_child(segment)
                    end
                end
            end

            root.sort!
        end
    end

    class SideNavTag < Liquid::Tag
        def initialize(tag_name, text, tokens)
            super
        end

        def render_menu_items(items, baseurl, wrappers_build = false)
            out = "<ul>"
            items.each do |item|
                expanded = item.has_children

                css_class = item.tags.map { |t| "tag-#{t.strip}" }
                css_class = css_class.concat(["expanded"]) if expanded
                out << "<li class='#{css_class.join(' ')}'>"
                if wrappers_build
                    out << item.wrapper_link(baseurl, @current)
                else
                    out << item.link(baseurl, @current)
                end
                if expanded
                    out << render_menu_items(item.children, baseurl, wrappers_build)
                end
                out << "</li>"
            end
            out << "</ul>"
            out
        end

        def render(context)
            @current = context['page']['url']
            site = context['site']
            if context['page']['node']
                render_menu_items(context['page']['node'].section_menu, site['baseurl'], site['wrappers_build'])
            else
                p context['page'], "missing node"
            end
        end
    end

    class BreadCrumbTag < Liquid::Tag
        def render(context)
            site = context['site']
            context['page']['node'].bread_crumb(site['baseurl'], site['wrappers_build'])
        end
    end
end

Liquid::Template.register_tag('render_side_nav', Jekyll::SideNavTag)
Liquid::Template.register_tag('render_bread_crumbs', Jekyll::BreadCrumbTag)
