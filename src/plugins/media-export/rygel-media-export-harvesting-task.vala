/*
 * Copyright (C) 2009 Jens Georg <mail@jensge.org>.
 *
 * This file is part of Rygel.
 *
 * Rygel is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Rygel is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

using GLib;
using Gee;

public class Rygel.MediaExport.HarvestingTask : Rygel.StateMachine, GLib.Object {
    public File origin;
    private MetadataExtractor extractor;
    private MediaCache cache;
    private GLib.Queue<MediaContainer> containers;
    private Gee.Queue<File> files;
    private RecursiveFileMonitor monitor;
    private Regex file_filter;
    private string flag;
    private MediaContainer parent;

    public Cancellable cancellable { get; set; }

    private const string HARVESTER_ATTRIBUTES =
                                        FILE_ATTRIBUTE_STANDARD_NAME + "," +
                                        FILE_ATTRIBUTE_STANDARD_TYPE + "," +
                                        FILE_ATTRIBUTE_TIME_MODIFIED + "," +
                                        FILE_ATTRIBUTE_STANDARD_SIZE;


    public HarvestingTask (MetadataExtractor    extractor,
                           RecursiveFileMonitor monitor,
                           Regex                file_filter,
                           File                 file,
                           MediaContainer       parent,
                           string?              flag = null) {
        this.extractor = extractor;
        this.origin = file;
        this.parent = parent;

        try {
            this.cache = MediaCache.get_default ();
        } catch (Error error) {
            // This should not happen. As the harvesting tasks are created
            // long after the first call to get_default which - if fails -
            // will make the whole root-container creation fail
            assert_not_reached ();
        }

        this.extractor.extraction_done.connect (on_extracted_cb);
        this.extractor.error.connect (on_extractor_error_cb);

        this.files = new LinkedList<File> ();
        this.containers = new GLib.Queue<MediaContainer> ();
        this.monitor = monitor;
        this.cancellable = new Cancellable ();
        this.flag = flag;
        this.file_filter = file_filter;
    }

    /**
     * Extract all metainformation from a given file.
     *
     * What action will be taken depends on the arguments
     * * file is a simple file. Then only information of this
     *   file will be extracted
     * * file is a directory and recursive is false. The children
     *   of the directory (if not directories themselves) will be
     *   enqueued for extraction
     * * file is a directory and recursive is true. ++ All ++ children
     *   of the directory will be enqueued for extraction, even directories
     *
     * No matter how many children are contained within file's hierarchy,
     * only one event is sent when all the children are done.
     */
    public async void run () {
        try {
            var info = yield this.origin.query_info_async (
                                        HARVESTER_ATTRIBUTES,
                                        FileQueryInfoFlags.NONE,
                                        Priority.DEFAULT,
                                        this.cancellable);

            if (this.process_file (this.origin, info, this.parent)) {
                if (info.get_file_type () != FileType.DIRECTORY) {
                    this.containers.push_tail (this.parent);
                }
                Idle.add (this.on_idle);
            } else {
                this.completed ();
            }
        } catch (Error error) {
            warning (_("Failed to harvest file %s: %s"),
                     this.origin.get_uri (),
                     error.message);
            this.completed ();
        }
    }

    /**
     * Add a file to the meta-data extraction queue.
     *
     * The file will only be added to the queue if one of the following
     * conditions is met:
     *   - The file is not in the cache
     *   - The current mtime of the file is larger than the cached
     *   - The size has changed
     * @param file to check
     * @param info FileInfo of the file to check
     * @return true, if the file has been queued, false otherwise.
     */
    private bool push_if_changed_or_unknown (File       file,
                                             FileInfo   info) {
        var id = Item.get_id (file);
        int64 timestamp;
        try {
            if (this.cache.exists (id, out timestamp)) {
                int64 mtime = (int64) info.get_attribute_uint64 (
                                        FILE_ATTRIBUTE_TIME_MODIFIED);

                // Doing the check for mtime here first because the check for
                // size involves a database query and if the size has changed,
                // the mtime probably has as well (unfortunatly enough
                // exceptions exist)
                if (mtime > timestamp) {
                    this.files.offer (file);

                    return true;
                } else {
                    // check size
                    var size = info.get_size ();
                    var item = cache.get_item (id);
                    if (item.size != size) {
                        this.files.offer (file);

                        return true;
                    }
                }
            } else {
                this.files.offer (file);

                return true;
            }
        } catch (Error error) {
            warning (_("Failed to query database: %s"), error.message);
        }

        return false;
    }

    private bool process_file (File           file,
                               FileInfo       info,
                               MediaContainer parent) {
        if (info.get_name ()[0] == '.') {
            return false;
        }

        if (info.get_file_type () == FileType.DIRECTORY) {
            // queue directory for processing later
            monitor.monitor (file);
            var container = new DummyContainer (file, parent);
            this.containers.push_tail (container);
            try {
                int64 timestamp;
                if (!this.cache.exists (container.id, out timestamp)) {
                    this.cache.save_container (container);
                }
            } catch (Error err) {
                warning (_("Failed to update database: %s"), err.message);

                return false;
            }

            return true;
        } else {
            // Check if the file needs to be harvested at all either because
            // it is denied by filter or it hasn't updated
            if (this.file_filter != null &&
                !this.file_filter.match (file.get_uri ())) {
                return false;
            }

             return this.push_if_changed_or_unknown (file, info);
        }
    }

    private bool process_children (GLib.List<FileInfo>? list) {
        if (list == null || this.cancellable.is_cancelled ()) {
            return false;
        }

        var parent_container = this.container ();

        foreach (var info in list) {
            var dir = parent_container.file;
            var file = dir.get_child (info.get_name ());
            parent_container.seen (Item.get_id (file));
            this.process_file (file, info, parent_container);
        }

        return true;
    }

    private async void enumerate_directory (File directory) {
        try {
            var enumerator = yield directory.enumerate_children_async (
                                        HARVESTER_ATTRIBUTES,
                                        FileQueryInfoFlags.NONE,
                                        Priority.DEFAULT,
                                        this.cancellable);

            GLib.List<FileInfo> list = null;
            do {
                list = yield enumerator.next_files_async (256,
                                                          Priority.DEFAULT,
                                                          this.cancellable);
            } while (this.process_children (list));

            yield enumerator.close_async (Priority.DEFAULT, this.cancellable);
        } catch (Error err) {
            warning (_("failed to enumerate folder: %s"), err.message);
        }

        this.cleanup_database ();
        this.do_update ();
    }

    private void cleanup_database () {
        // delete all children which are not in filesystem anymore
        var container = this.container ();
        try {
            foreach (var child in container.children) {
                this.cache.remove_by_id (child);
            }
        } catch (DatabaseError error) {
            warning (_("Failed to get children of container %s: %s"),
                     container.id,
                     error.message);
        }

    }

    private bool on_idle () {
        if (this.cancellable.is_cancelled ()) {
            this.completed ();

            return false;
        }

        if (this.files.size > 0) {
            var candidate = this.file ();
            this.extractor.extract (candidate);
        } else if (this.containers.get_length () > 0) {
            var container = this.container ();
            var directory = container.file;
            this.enumerate_directory (directory);
        } else {
            // nothing to do
            if (this.flag != null) {
                try {
                    this.cache.flag_object (Item.get_id (this.origin),
                                            this.flag);
                } catch (Error error) {};
            }
            this.completed ();
        }

        return false;
    }

    private void on_extracted_cb (File                   file,
                                  GUPnP.DLNAInformation? dlna,
                                  string                 mime,
                                  uint64                 size,
                                  uint64                 mtime) {
        if (this.cancellable.is_cancelled ()) {
            this.completed ();
        }

        var entry = this.files.peek ();
        if (entry == null) {
            // this event may be triggered by another instance
            // just ignore it
           return;
        }

        if (file == entry) {
            MediaItem item;
            if (dlna == null) {
                item = new Item.simple (this.current_parent (),
                                        file,
                                        mime,
                                        size,
                                        mtime);
            } else {
                item = Item.create_from_info (this.current_parent (),
                                              file,
                                              dlna,
                                              mime,
                                              size,
                                              mtime);
            }

            if (item != null) {
                item.parent_ref = this.current_parent ();
                try {
                    this.cache.save_item (item);
                } catch (Error error) {
                    // Ignore it for now
                }
            }

            this.files.poll ();
            this.do_update ();
        }
    }

    private void on_extractor_error_cb (File file, Error error) {
        var entry = this.file ();
        if (entry == null) {
            // this event may be triggered by another instance
            // just ignore it
            return;
        }

        if (file == entry) {
            this.files.poll ();
            this.do_update ();
        }
    }

    /**
     * If all files of a container were processed, notify the container
     * about this and set the updating signal.
     * Reschedule the iteration and extraction
     */
    private void do_update () {
        if (this.files.size == 0 &&
            this.containers.get_length () != 0) {
            this.current_parent ().updated ();
            this.containers.pop_head ();
        }

        Idle.add (this.on_idle);
    }

    private DummyContainer container() {
        return this.containers.peek_head () as DummyContainer;
    }

    private File file () {
        return this.files.peek ();
    }

    private inline MediaContainer current_parent () {
        return this.containers.peek_head ();
    }
}